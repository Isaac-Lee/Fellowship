import Foundation
import Speech
import Translation
import AVFoundation
import CoreMedia
import os
import Accelerate

/// Mic -> converted buffers for the active lane, plus RMS endpointing. Not isolated: the tap runs on an audio thread.
final class LiveMicFeeder: @unchecked Sendable {
    enum Sink { case none, zh, ko }

    private struct State {
        var sink = Sink.none
        var zhCont: AsyncStream<AnalyzerInput>.Continuation?
        var koCont: AsyncStream<AnalyzerInput>.Continuation?
        var zhTarget: AVAudioFormat?
        var koTarget: AVAudioFormat?
        var timeline = 0.0                 // monotonic seconds of audio seen; independent of the input sample rate
        var zhFrames: Int64 = 0            // lane clocks, in output frames at each lane's target rate
        var koFrames: Int64 = 0
        var zhStamps = 0                   // DEBUG: stamps logged since last (re)start
        var koStamps = 0
        var zhEnd = CMTime.zero            // lane-clock end of last buffer fed to each lane
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
    /// No-op if the engine is still running at the same input rate.
    func restart() throws {
        if engine.isRunning, engine.inputNode.outputFormat(forBus: 0).sampleRate == tapRate { return }
        stopEngine()
        try startEngine()
    }
    private var tapRate = 0.0
    private var restarts = 0

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
        tapRate = inFmt.sampleRate
        state.withLock { $0.zhStamps = 0; $0.koStamps = 0 }
        restarts += 1
        #if DEBUG
        print("[AUDIO] engine restart #\(restarts) inputRate=\(inFmt.sampleRate)")
        #endif
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
            vDSP_rmsqv(ch, 1, &rms, vDSP_Length(buf.frameLength))
        }
        let dur = Double(buf.frameLength) / inFmt.sampleRate
        let voiced = rms > LiveListeningEngine.voiceRMSThreshold

        // Wall timeline + endpoint decision under the lock; lane stamps are assigned after conversion.
        let (sink, wall, cont, endpoint): (Sink, Double, AsyncStream<AnalyzerInput>.Continuation?, CMTime?) = state.withLock { s in
            var endpoint: CMTime?
            let wall = s.timeline
            s.timeline += dur
            if voiced { s.lastVoiceDate = Date(); s.silence = 0; s.speechSeen = true }
            else if s.speechSeen { s.silence += dur }
            if s.sink == .zh, s.speechSeen, !voiced, s.silence >= LiveListeningEngine.silenceToFinalize {
                endpoint = s.lastVoicedEnd; s.speechSeen = false; s.silence = 0 // already in lane-clock time
            }
            return (s.sink, wall, s.sink == .zh ? s.zhCont : s.sink == .ko ? s.koCont : nil, endpoint)
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
        guard err == nil, out.frameLength > 0 else { return }

        // Lane clock in OUTPUT frames: the converter buffers, so out.frameLength != input duration.
        // Jumps forward to the wall timeline when the lane was idle, never backward.
        let rate = target.sampleRate
        let outFrames = Int64(out.frameLength)
        let ts = Int32(rate)
        let (start, logIt): (CMTime, Bool) = state.withLock { s in
            var frames = sink == .zh ? s.zhFrames : s.koFrames
            frames = max(frames, Int64(wall * rate))
            let start = CMTime(value: frames, timescale: ts)
            frames += outFrames
            let end = CMTime(value: frames, timescale: ts)
            var n = sink == .zh ? s.zhStamps : s.koStamps
            let logIt = n < 3; n += 1
            if sink == .zh { s.zhFrames = frames; s.zhEnd = end; s.zhStamps = n } else { s.koFrames = frames; s.koEnd = end; s.koStamps = n }
            if voiced { s.lastVoicedEnd = end }
            return (start, logIt)
        }
        #if DEBUG
        if logIt { print("[AUDIO] stamp \(sink == .zh ? "zh" : "ko") start=\(start.seconds) dur=\(Double(out.frameLength) / rate)") }
        #endif
        cont.yield(AnalyzerInput(buffer: out, bufferStartTime: start))
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
    private var lastPartnerPartial = "", lastMyPartial = ""
    private var lastRestart = Date.distantPast
    private var restartPending = false
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
            koFinals = []; koVolatile = ""; lastMyPartial = ""; koState = .collecting
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
            let zhText = try await translate(text, partner: false)
            continuation?.yield(.myFinal(ko: text, zh: zhText))
            log("[LAT] mine voiceEnd→final \(ms(from: released, to: tFinal)) →translated \(ms(from: released, to: Date()))")
        } catch {
            log("[ENGINE] translate failed: ko→zh \(error)")
            continuation?.yield(.myFailed)
        }
    }

    /// partner: zh→ko (serial partner worker), else ko→zh (my turn). Each direction has its own session.
    /// CancellationError (seen when another translation consumer is active) is retried once on a fresh session.
    private func translate(_ text: String, partner: Bool) async throws -> String {
        for attempt in 0..<2 {
            guard let s = partner ? zhToKo : koToZh else { throw NSError(domain: "LiveListeningEngine", code: 2) }
            nonisolated(unsafe) let sess = s // SDK hands a MainActor session to a @concurrent method
            do { return try await sess.translate(text).targetText }
            catch is CancellationError where attempt == 0 && !Task.isCancelled {
                log("[ENGINE] translate failed: CancellationError, retrying with a fresh session")
                if partner { zhToKo = TranslationSession(installedSource: zhHant, target: koLang) }
                else { koToZh = TranslationSession(installedSource: koLang, target: zhHant) }
            }
        }
        throw CancellationError()
    }

    // MARK: Results

    private func handleZh(_ text: String, isFinal: Bool) {
        guard zh?.dropping == false else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if isFinal { log("[ENGINE] zh final: \(t)"); lastPartnerPartial = ""; partnerQueue?.yield((t, feeder.lastVoiceDate)) }
        else if t != lastPartnerPartial { lastPartnerPartial = t; continuation?.yield(.partnerPartial(t)) }
    }

    private func handleKo(_ text: String, isFinal: Bool) {
        guard ko?.dropping == false, koState != .idle else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal { log("[ENGINE] ko final: \(t)"); if !t.isEmpty { koFinals.append(t) }; koVolatile = "" } else { koVolatile = t }
        if koState == .collecting {
            let all = (koFinals + [koVolatile]).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !all.isEmpty, all != lastMyPartial { lastMyPartial = all; continuation?.yield(.myPartial(all)) }
        }
    }

    private func runPartnerWorker(_ queue: AsyncStream<(text: String, voice: Date)>) async {
        for await item in queue { // sequential: sentences stay in order even if translations are slow
            let tFinal = Date()
            do {
                let ko = try await translate(item.text, partner: true)
                if Task.isCancelled { return }
                continuation?.yield(.partnerFinal(zh: item.text, ko: ko))
                log("[LAT] partner speechEnd→final \(ms(from: item.voice, to: tFinal)) →translated \(ms(from: item.voice, to: Date()))")
            } catch { log("[ENGINE] translate failed: zh→ko \(error)") }
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
        observers = Self.observe { @MainActor [weak self] reactivate in self?.restartAudio(reactivate: reactivate) }
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

    /// Debounced: at most one restart per 0.5 s, with one trailing restart for notifications that arrive inside the window.
    private func restartAudio(reactivate: Bool) {
        guard running, mode != .paused else { return }
        let wait = 0.5 - Date().timeIntervalSince(lastRestart)
        if wait > 0 && !reactivate {
            guard !restartPending else { return }
            restartPending = true
            Task { try? await Task.sleep(for: .seconds(wait)); restartPending = false; restartAudio(reactivate: false) }
            return
        }
        lastRestart = Date()
        do {
            if reactivate { try AudioSessionSetup.activate() } // interruption ended: session was deactivated
            try feeder.restart()
        } catch { log("[ENGINE] audio restart failed: \(error)") }
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
        lastPartnerPartial = ""; lastMyPartial = ""; restartPending = false
        koState = .idle; koFinals = []; koVolatile = ""
        running = false
    }

    private func missingData(_ why: String) {
        log("[ENGINE] missing data: \(why)")
        onMissingData?()
    }

    // Notification observers are built in a nonisolated context: they fire on arbitrary threads.
    nonisolated private static func observe(_ hop: @escaping @Sendable @MainActor (_ reactivate: Bool) -> Void) -> [NSObjectProtocol] {
        [.AVAudioEngineConfigurationChange, AVAudioSession.interruptionNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { @Sendable note in
                if name == AVAudioSession.interruptionNotification,
                   (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) != AVAudioSession.InterruptionType.ended.rawValue { return }
                let reactivate = name == AVAudioSession.interruptionNotification
                Task { @MainActor in hop(reactivate) }
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
