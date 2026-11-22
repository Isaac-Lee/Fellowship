import Foundation
import Speech
import Translation
import AVFoundation
import CoreMedia
import os

/// Mic -> converted buffers for the active lane, plus RMS endpointing. Not isolated: the tap runs on an audio thread.
final class LiveMicFeeder: @unchecked Sendable {
    enum Sink { case none, zh, ko }

    private struct State {
        var sink = Sink.none
        var zhCont: AsyncStream<AnalyzerInput>.Continuation?
        var koCont: AsyncStream<AnalyzerInput>.Continuation?
        var zhTarget: AVAudioFormat?
        var koTarget: AVAudioFormat?
        var inFrames: Int64 = 0            // running timeline in input frames (continuous across sink switches)
        var zhEnd = CMTime.zero            // end of last buffer fed to each lane
        var koEnd = CMTime.zero
        var speechSeen = false
        var silence: TimeInterval = 0
        var lastVoicedEnd = CMTime.zero
        var lastVoiceDate = Date.distantPast
    }

    private let engine = AVAudioEngine()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var converters: [Sink: AVAudioConverter] = [:]
    private var onEndpoint: (@Sendable (CMTime) -> Void)?

    var lastVoiceDate: Date { state.withLock { $0.lastVoiceDate } }
    func lastEnd(_ s: Sink) -> CMTime { state.withLock { s == .zh ? $0.zhEnd : $0.koEnd } }

    func setSink(_ s: Sink) {
        state.withLock { $0.sink = s; $0.speechSeen = false; $0.silence = 0 }
    }

    func start(zh: (AsyncStream<AnalyzerInput>.Continuation, AVAudioFormat),
               ko: (AsyncStream<AnalyzerInput>.Continuation, AVAudioFormat),
               onEndpoint: @escaping @Sendable (CMTime) -> Void) throws {
        self.onEndpoint = onEndpoint
        state.withLock { $0.zhCont = zh.0; $0.koCont = ko.0; $0.zhTarget = zh.1; $0.koTarget = ko.1 }
        try startEngine()
    }

    /// Reinstall the tap (after a config change / interruption). Lanes and timeline stay.
    func restart() throws {
        stopEngine()
        try startEngine()
    }

    func stop() {
        stopEngine()
        state.withLock { $0 = State() }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0 else { throw NSError(domain: "LiveMicFeeder", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input format"]) }
        let (zt, kt) = state.withLock { ($0.zhTarget, $0.koTarget) }
        converters = [:]
        if let zt, let c = AVAudioConverter(from: inFmt, to: zt) { converters[.zh] = c }
        if let kt, let c = AVAudioConverter(from: inFmt, to: kt) { converters[.ko] = c }
        input.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { @Sendable [self] buf, _ in
            handle(buf, inFmt: inFmt)
        }
        engine.prepare()
        try engine.start()
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func handle(_ buf: AVAudioPCMBuffer, inFmt: AVAudioFormat) {
        guard buf.frameLength > 0 else { return }
        var rms: Float = 0
        if let ch = buf.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
            rms = (sum / Float(buf.frameLength)).squareRoot()
        }
        let rate = Int32(inFmt.sampleRate)
        let dur = Double(buf.frameLength) / inFmt.sampleRate
        let voiced = rms > LiveListeningEngine.voiceRMSThreshold

        // Update timeline + endpoint decision under the lock; do the slow work outside.
        let frames = Int64(buf.frameLength)
        let (sink, start, cont, endpoint): (Sink, CMTime, AsyncStream<AnalyzerInput>.Continuation?, CMTime?) = state.withLock { s in
            var endpoint: CMTime?
            let start = CMTime(value: s.inFrames, timescale: rate)
            s.inFrames += frames
            let end = CMTime(value: s.inFrames, timescale: rate)
            if voiced { s.lastVoiceDate = Date(); s.lastVoicedEnd = end; s.silence = 0; s.speechSeen = true }
            else if s.speechSeen { s.silence += dur }
            if s.sink == .zh, s.speechSeen, !voiced, s.silence >= LiveListeningEngine.silenceToFinalize {
                endpoint = s.lastVoicedEnd; s.speechSeen = false; s.silence = 0
            }
            if s.sink == .zh { s.zhEnd = end } else if s.sink == .ko { s.koEnd = end }
            return (s.sink, start, s.sink == .zh ? s.zhCont : s.sink == .ko ? s.koCont : nil, endpoint)
        }
        if let endpoint { onEndpoint?(endpoint) }
        guard sink != .none, let cont, let conv = converters[sink] else { return }

        let target = conv.outputFormat
        let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / inFmt.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        let given = OSAllocatedUnfairLock(initialState: false)
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if given.withLock({ let was = $0; $0 = true; return was }) { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            return buf
        }
        if err == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out, bufferStartTime: start)) }
    }
}

@MainActor
final class LiveListeningEngine: ListeningEngine {
    /// Silence after speech (partner mode) that forces a final result.
    nonisolated static let silenceToFinalize: TimeInterval = 0.7
    /// RMS level above which a buffer counts as voice.
    nonisolated static let voiceRMSThreshold: Float = 0.01

    /// Called when a speech/translation model turns out not to be installed.
    var onMissingData: (@MainActor () -> Void)?

    @MainActor private final class Lane {
        let analyzer: SpeechAnalyzer
        let transcriber: SpeechTranscriber
        let format: AVAudioFormat
        let cont: AsyncStream<AnalyzerInput>.Continuation
        var task: Task<Void, Never>?
        var dropping = false // results ignored while a flush runs
        init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, format: AVAudioFormat, cont: AsyncStream<AnalyzerInput>.Continuation) {
            self.analyzer = analyzer; self.transcriber = transcriber; self.format = format; self.cont = cont
        }
        /// Force finals through `t`, ignoring whatever they produce.
        func flush(through t: CMTime) async {
            dropping = true
            try? await analyzer.finalize(through: t)
            try? await Task.sleep(for: .milliseconds(150))
            dropping = false
        }
    }

    private enum KoState { case idle, collecting, finalizing }

    private let zhHant = Locale.Language(identifier: "zh-Hant")
    private let koLang = Locale.Language(identifier: "ko")
    private let feeder = LiveMicFeeder()
    private var continuation: AsyncStream<ListenEvent>.Continuation?
    private var mode = ListenMode.paused
    private var running = false, starting = false
    private var zh: Lane?, ko: Lane?
    private var startTask: Task<Void, Never>?
    private var partnerQueue: AsyncStream<(text: String, voice: Date)>.Continuation?
    private var partnerWorker: Task<Void, Never>?
    private var zhToKo: TranslationSession?, koToZh: TranslationSession?
    private var koState = KoState.idle
    private var koFinals: [String] = []
    private var koVolatile = ""
    private var observers: [NSObjectProtocol] = []

    // MARK: ListeningEngine

    func events() -> AsyncStream<ListenEvent> {
        continuation?.finish()
        let (stream, c) = AsyncStream.makeStream(of: ListenEvent.self)
        continuation = c
        return stream
    }

    func setMode(_ new: ListenMode) {
        mode = new
        switch new {
        case .paused: teardown()
        case .partner:
            if running { applySink() } else { startIfNeeded() }
        case .me:
            koFinals = []; koVolatile = ""; koState = .collecting
            applySink()
        }
    }

    func endMine(valid: Bool) {
        guard mode == .me else { return }
        mode = .partner
        let koEnd = feeder.lastEnd(.ko)
        let released = feeder.lastVoiceDate
        applySink() // partner line resumes immediately
        guard valid else {
            koState = .idle
            if let ko { Task { await ko.flush(through: koEnd) } }
            return
        }
        // The paused partner line is dropped.
        if let zh { let zEnd = feeder.lastEnd(.zh); Task { await zh.flush(through: zEnd) } }
        koState = .finalizing
        Task { await finishMine(koEnd: koEnd, released: released) }
    }

    // MARK: My turn

    // ponytail: a second press while the previous one is still finalizing shares koFinals; fine for a human-speed button.
    private func finishMine(koEnd: CMTime, released: Date) async {
        guard let ko else { koState = .idle; continuation?.yield(.myFailed); return }
        try? await ko.analyzer.finalize(through: koEnd)
        try? await Task.sleep(for: .milliseconds(150))
        let text = (koFinals + [koVolatile]).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if koState == .finalizing { koState = .idle }
        let tFinal = Date()
        guard !text.isEmpty else { continuation?.yield(.myFailed); return }
        do {
            guard let s = koToZh else { throw NSError(domain: "LiveListeningEngine", code: 2) }
            nonisolated(unsafe) let sess = s // SDK hands a MainActor session to a @concurrent method
            let r = try await sess.translate(text)
            continuation?.yield(.myFinal(ko: text, zh: r.targetText))
            log("[LAT] mine voiceEnd→final \(ms(from: released, to: tFinal)) →translated \(ms(from: released, to: Date()))")
        } catch {
            log("[ENGINE] ko→zh translate failed: \(error)")
            continuation?.yield(.myFailed)
        }
    }

    // MARK: Results

    private func handleZh(_ text: String, isFinal: Bool) {
        guard zh?.dropping == false else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if isFinal { partnerQueue?.yield((t, feeder.lastVoiceDate)) }
        else { continuation?.yield(.partnerPartial(t)) }
    }

    private func handleKo(_ text: String, isFinal: Bool) {
        guard ko?.dropping == false, koState != .idle else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal { if !t.isEmpty { koFinals.append(t) }; koVolatile = "" } else { koVolatile = t }
        if koState == .collecting {
            let all = (koFinals + [koVolatile]).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !all.isEmpty { continuation?.yield(.myPartial(all)) }
        }
    }

    private func runPartnerWorker(_ queue: AsyncStream<(text: String, voice: Date)>) async {
        for await item in queue { // sequential: sentences stay in order even if translations are slow
            let tFinal = Date()
            guard let s = zhToKo else { continue }
            do {
                nonisolated(unsafe) let sess = s
                let r = try await sess.translate(item.text)
                if Task.isCancelled { return }
                continuation?.yield(.partnerFinal(zh: item.text, ko: r.targetText))
                log("[LAT] partner speechEnd→final \(ms(from: item.voice, to: tFinal)) →translated \(ms(from: item.voice, to: Date()))")
            } catch { log("[ENGINE] zh→ko translate failed: \(error)") }
        }
    }

    // MARK: Lifecycle

    private func applySink() {
        feeder.setSink(mode == .partner ? .zh : mode == .me ? .ko : .none)
    }

    private func startIfNeeded() {
        guard !running, !starting else { return }
        starting = true
        startTask = Task {
            do { try await start() ; running = true }
            catch { log("[ENGINE] start failed: \(error)") }
            starting = false
            if running { if mode == .paused { teardown() } else { applySink() } }
        }
    }

    private func start() async throws {
        try AudioSessionSetup.activate()
        guard let zhLoc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-TW")),
              let koLoc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ko-KR")) else {
            missingData("speech locale unsupported"); throw CancellationError()
        }
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        guard installed.contains(zhLoc.identifier(.bcp47)), installed.contains(koLoc.identifier(.bcp47)) else {
            missingData("speech model not installed"); throw CancellationError()
        }
        let av = LanguageAvailability()
        let a = await av.status(from: zhHant, to: koLang), b = await av.status(from: koLang, to: zhHant)
        guard a == .installed, b == .installed else { missingData("translation not installed"); throw CancellationError() }
        try Task.checkCancellation()

        let zhLane = try await makeLane(zhLoc), koLane = try await makeLane(koLoc)
        zhToKo = TranslationSession(installedSource: zhHant, target: koLang)
        koToZh = TranslationSession(installedSource: koLang, target: zhHant)
        zh = zhLane; ko = koLane
        zhLane.task = Task { [weak self] in
            do { for try await r in zhLane.transcriber.results { self?.handleZh(String(r.text.characters), isFinal: r.isFinal) } }
            catch { self?.log("[ENGINE] zh results: \(error)") }
        }
        koLane.task = Task { [weak self] in
            do { for try await r in koLane.transcriber.results { self?.handleKo(String(r.text.characters), isFinal: r.isFinal) } }
            catch { self?.log("[ENGINE] ko results: \(error)") }
        }
        let (q, qc) = AsyncStream.makeStream(of: (text: String, voice: Date).self)
        partnerQueue = qc
        partnerWorker = Task { await runPartnerWorker(q) }

        try feeder.start(zh: (zhLane.cont, zhLane.format), ko: (koLane.cont, koLane.format)) { [weak self] t in
            Task { @MainActor in self?.endpoint(t) }
        }
        observers = Self.observe { @MainActor [weak self] in self?.restartAudio() }
    }

    private func makeLane(_ loc: Locale) async throws -> Lane {
        let tr = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [tr]) else {
            throw NSError(domain: "LiveListeningEngine", code: 3, userInfo: [NSLocalizedDescriptionKey: "no audio format"])
        }
        let analyzer = SpeechAnalyzer(modules: [tr])
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)
        return Lane(analyzer: analyzer, transcriber: tr, format: fmt, cont: cont)
    }

    /// VAD saw speech then silence in partner mode: force a final through the last voiced buffer.
    private func endpoint(_ t: CMTime) {
        guard mode == .partner, let zh else { return }
        Task { try? await zh.analyzer.finalize(through: t) }
    }

    private func restartAudio() {
        guard running, mode != .paused else { return }
        do { try AudioSessionSetup.activate(); try feeder.restart() }
        catch { log("[ENGINE] audio restart failed: \(error)") }
    }

    private func teardown() {
        startTask?.cancel()
        feeder.stop()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        partnerQueue?.finish(); partnerQueue = nil
        partnerWorker?.cancel(); partnerWorker = nil
        for lane in [zh, ko].compactMap({ $0 }) {
            lane.cont.finish(); lane.task?.cancel()
            let a = lane.analyzer
            Task { await a.cancelAndFinishNow() }
        }
        zh = nil; ko = nil; zhToKo = nil; koToZh = nil
        koState = .idle; koFinals = []; koVolatile = ""
        running = false
    }

    private func missingData(_ why: String) {
        log("[ENGINE] missing data: \(why)")
        onMissingData?()
    }

    // Notification observers are built in a nonisolated context: they fire on arbitrary threads.
    nonisolated private static func observe(_ hop: @escaping @Sendable @MainActor () -> Void) -> [NSObjectProtocol] {
        [.AVAudioEngineConfigurationChange, AVAudioSession.interruptionNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { @Sendable note in
                if name == AVAudioSession.interruptionNotification,
                   (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) != AVAudioSession.InterruptionType.ended.rawValue { return }
                Task { @MainActor in hop() }
            }
        }
    }

    private func ms(from a: Date, to b: Date) -> Int { Int(b.timeIntervalSince(a) * 1000) }
    private func log(_ s: String) {
        #if DEBUG
        print(s)
        #endif
    }
}
