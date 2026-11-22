import Foundation
import Speech
import Translation
import AVFoundation
import CoreMedia
import os
import Accelerate

/// Mic -> converted buffers for the active lane, plus RMS endpointing. Not isolated: the tap runs on an audio thread.
/// The AVAudioEngine runs whenever the listening engine is live (not paused), whatever the sink: a mode switch is only
/// a sink change under the lock. All engine start/stop work happens on `audioQ`, never on the main actor.
final class LiveMicFeeder: @unchecked Sendable {
    enum Sink { case none, zh, ko }

    private struct Chunk: @unchecked Sendable { var wall: Double; var dur: Double; var buf: AVAudioPCMBuffer }

    private struct State: @unchecked Sendable {
        var sink = Sink.none
        var zhCont: AsyncStream<AnalyzerInput>.Continuation?
        var koCont: AsyncStream<AnalyzerInput>.Continuation?
        var zhTarget: AVAudioFormat?
        var koTarget: AVAudioFormat?
        var converters: [Sink: AVAudioConverter] = [:]   // written on audioQ (startEngine), read on the audio thread: lock only
        var onEndpoint: (@Sendable (CMTime) -> Void)?
        var timeline = 0.0                 // monotonic seconds of audio seen; independent of the input sample rate
        var zhFrames: Int64 = 0            // lane clocks, in output frames at each lane's target rate
        var koFrames: Int64 = 0
        var zhStamps = 0                   // DEBUG: stamps logged since last (re)start
        var koStamps = 0
        var zhEnd = CMTime.zero            // lane-clock end of last buffer fed to each lane
        var koEnd = CMTime.zero
        var koWallEnd = 0.0                // wall time up to which audio was already fed to the ko lane
        var ring: [Chunk] = []             // last `preRoll` seconds of raw input, whatever the sink
        var needPreRoll = false            // sink just switched to .ko
        var speechSeen = false
        var silence: TimeInterval = 0
        var span: TimeInterval = 0         // seconds since speech began without an endpoint
        var lastVoicedEnd = CMTime.zero
        var lastVoiceDate = Date.distantPast
        var rmsHist: [(t: Double, rms: Float)] = []   // last few seconds, for the adaptive noise floor
    }

    private let engine = AVAudioEngine()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let audioQ = DispatchQueue(label: "fellowship.audio.engine")
    private let wanted = OSAllocatedUnfairLock(initialState: false)   // engine should be running
    // audioQ-confined:
    private var tapRate = 0.0
    private var restarts = 0
    private var vpTried = false

    var lastVoiceDate: Date { state.withLock { $0.lastVoiceDate } }
    func lastEnd(_ s: Sink) -> CMTime { state.withLock { s == .zh ? $0.zhEnd : $0.koEnd } }

    /// Only a sink change: no audio-engine work, safe on the main actor at button speed.
    func setSink(_ s: Sink) {
        state.withLock {
            if s == .ko, $0.sink != .ko { $0.needPreRoll = true }
            $0.sink = s; $0.speechSeen = false; $0.silence = 0; $0.span = 0
        }
    }

    /// Lanes + endpoint callback. Does not touch the audio engine.
    func configure(zh: (AsyncStream<AnalyzerInput>.Continuation, AVAudioFormat),
                   ko: (AsyncStream<AnalyzerInput>.Continuation, AVAudioFormat),
                   onEndpoint: @escaping @Sendable (CMTime) -> Void) {
        state.withLock { $0.zhCont = zh.0; $0.koCont = ko.0; $0.zhTarget = zh.1; $0.koTarget = ko.1; $0.onEndpoint = onEndpoint }
    }

    /// Start the engine, or reinstall the tap after a config change / interruption, on the audio queue.
    /// Returns immediately; `completion` (any thread) gets the final error, if any. Lanes and timeline stay.
    func start(reactivate: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        wanted.withLock { $0 = true }
        audioQ.async { [self] in
            guard wanted.withLock({ $0 }) else { return }
            do {
                if reactivate { try AudioSessionSetup.activate() } // interruption ended / app returned: session may be deactivated
                try restart()
                completion(nil)
            } catch {
                #if DEBUG
                print("[ENGINE] audio start failed: \(error)")
                #endif
                try? AudioSessionSetup.activate()
                do { try restart(); completion(nil) } catch { completion(error) }
            }
        }
    }

    /// Full stop (teardown): lanes and counters reset now, the engine stops on the audio queue.
    func stop() {
        wanted.withLock { $0 = false }
        state.withLock { $0 = State() }
        audioQ.async { [self] in stopEngine() }
    }

    // MARK: audioQ only

    /// No-op if the engine is already running at the same input rate.
    private func restart() throws {
        if engine.isRunning, engine.inputNode.outputFormat(forBus: 0).sampleRate == tapRate { return }
        stopEngine()
        try startEngine()
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapRate = 0
        state.withLock { $0.speechSeen = false; $0.silence = 0; $0.span = 0 }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        if LiveListeningEngine.useVoiceProcessing, !vpTried { // once, before the first start; never toggled per press
            vpTried = true
            do {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                #if DEBUG
                print("[AUDIO] voiceProcessing=failed \(error); continuing without it")
                #endif
            }
        }
        let inFmt = input.outputFormat(forBus: 0) // after VP: the real input format
        guard inFmt.sampleRate > 0 else { throw NSError(domain: "LiveMicFeeder", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input format"]) }
        state.withLock { s in
            s.converters = [:]
            s.ring = []   // old buffers may have another format
            if let zt = s.zhTarget, let c = AVAudioConverter(from: inFmt, to: zt) { s.converters[.zh] = c }
            if let kt = s.koTarget, let c = AVAudioConverter(from: inFmt, to: kt) { s.converters[.ko] = c }
            s.zhStamps = 0; s.koStamps = 0
        }
        tapRate = inFmt.sampleRate
        restarts += 1
        #if DEBUG
        print("[AUDIO] engine restart #\(restarts) inputRate=\(inFmt.sampleRate)")
        print("[AUDIO] voiceProcessing=\(input.isVoiceProcessingEnabled ? "on" : "off") inputFormat=\(inFmt)")
        #endif
        input.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { @Sendable [self] buf, _ in
            handle(buf, inFmt: inFmt)
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: audio thread

    private struct Step {
        var sink: Sink
        var wall: Double
        var cont: AsyncStream<AnalyzerInput>.Continuation?
        var conv: AVAudioConverter?
        var endpoint: CMTime?
        var onEndpoint: (@Sendable (CMTime) -> Void)?
        var voiced: Bool
        var preRoll: [Chunk]
    }

    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let s = b.floatChannelData,
              let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength),
              let d = c.floatChannelData else { return nil }
        c.frameLength = b.frameLength
        for ch in 0..<Int(b.format.channelCount) { memcpy(d[ch], s[ch], Int(b.frameLength) * MemoryLayout<Float>.size) }
        return c
    }

    private func handle(_ buf: AVAudioPCMBuffer, inFmt: AVAudioFormat) {
        guard buf.frameLength > 0 else { return }
        var rms: Float = 0
        if let ch = buf.floatChannelData?[0] {
            vDSP_rmsqv(ch, 1, &rms, vDSP_Length(buf.frameLength))
        }
        let dur = Double(buf.frameLength) / inFmt.sampleRate
        let level = rms
        nonisolated(unsafe) let copy = Self.copy(buf)

        // Wall timeline + endpoint decision under the lock; lane stamps are assigned after conversion.
        let st: Step = state.withLock { s in
            let wall = s.timeline
            s.timeline += dur
            if let copy {
                s.ring.append(Chunk(wall: wall, dur: dur, buf: copy))
                while let f = s.ring.first, f.wall + f.dur <= wall + dur - LiveListeningEngine.preRoll { s.ring.removeFirst() }
            }
            // Adaptive threshold: noisy rooms raise the floor so silence can still be detected.
            s.rmsHist.removeAll { $0.t < wall - LiveListeningEngine.noiseWindow }
            let floor = s.rmsHist.map(\.rms).min()
            s.rmsHist.append((wall, level))
            var thr = LiveListeningEngine.voiceRMSThreshold
            if let floor { thr = min(max(thr, LiveListeningEngine.noiseFactor * floor), LiveListeningEngine.voiceRMSCeiling) }
            let voiced = level > thr
            var endpoint: CMTime?
            if voiced { s.lastVoiceDate = Date(); s.silence = 0; s.speechSeen = true }
            else if s.speechSeen { s.silence += dur }
            if s.speechSeen { s.span += dur }
            if s.sink == .zh, s.speechSeen, (!voiced && s.silence >= LiveListeningEngine.silenceToFinalize) || s.span >= LiveListeningEngine.maxVoiceSpan {
                endpoint = s.lastVoicedEnd; s.speechSeen = false; s.silence = 0; s.span = 0 // already in lane-clock time
            }
            let sink = s.sink
            var pre: [Chunk] = []
            if sink == .ko, s.needPreRoll {
                s.needPreRoll = false
                // Audio before the current buffer, minus what the ko lane already got (a quick second press).
                pre = s.ring.filter { $0.wall < wall && $0.wall >= s.koWallEnd - 1e-6 }
            }
            return Step(sink: sink, wall: wall, cont: sink == .zh ? s.zhCont : sink == .ko ? s.koCont : nil,
                        conv: s.converters[sink], endpoint: endpoint, onEndpoint: s.onEndpoint, voiced: voiced, preRoll: pre)
        }
        if let e = st.endpoint { st.onEndpoint?(e) }
        let sink = st.sink
        guard sink != .none, let cont = st.cont, let conv = st.conv else { return }

        if !st.preRoll.isEmpty {
            conv.reset() // drop converter tail from the previous turn; chunks below are contiguous
            #if DEBUG
            print("[AUDIO] preroll \(st.preRoll.count) chunks \(String(format: "%.2f", st.preRoll.reduce(0) { $0 + $1.dur }))s")
            #endif
            for c in st.preRoll { emit(c.buf, dur: c.dur, wall: c.wall, voiced: false, sink: sink, conv: conv, cont: cont) }
        }
        emit(buf, dur: dur, wall: st.wall, voiced: st.voiced, sink: sink, conv: conv, cont: cont)
    }

    /// Convert one raw buffer to the lane format and yield it stamped on the lane clock.
    private func emit(_ buf: AVAudioPCMBuffer, dur: Double, wall: Double, voiced: Bool, sink: Sink,
                      conv: AVAudioConverter, cont: AsyncStream<AnalyzerInput>.Continuation) {
        let target = conv.outputFormat
        let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate) + 16
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
            if sink == .zh { s.zhFrames = frames; s.zhEnd = end; s.zhStamps = n }
            else { s.koFrames = frames; s.koEnd = end; s.koStamps = n; s.koWallEnd = wall + dur }
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
    /// Base RMS level above which a buffer counts as voice.
    nonisolated static let voiceRMSThreshold: Float = 0.01
    /// Adaptive threshold = clamp(noiseFactor x minimum RMS over noiseWindow, base...ceiling).
    nonisolated static let noiseFactor: Float = 2.5
    nonisolated static let noiseWindow: TimeInterval = 3
    nonisolated static let voiceRMSCeiling: Float = 0.08
    /// Partner mode: volatile zh text unchanged this long forces a final.
    static let textStableToFinalize: TimeInterval = 0.8
    /// Partner mode: force a final after this much continuous voice.
    nonisolated static let maxVoiceSpan: TimeInterval = 8
    /// Each translation is abandoned after this long.
    static let translateTimeout: TimeInterval = 2.5
    /// Zh finals shorter than this (voiced audio) are dropped.
    static let minFinalDuration: TimeInterval = 0.4
    static let startRetryDelay: TimeInterval = 1
    /// Raw input kept so a press also recognizes the speech just before it.
    nonisolated static let preRoll: TimeInterval = 0.5
    /// Apple voice processing (echo cancel / noise suppression) on the input; set once before the first start.
    nonisolated static let useVoiceProcessing = true
    /// finishMine waits at most this long for a result covering the whole turn.
    static let finalResultWait: TimeInterval = 0.3

    /// Called when a speech/translation model turns out not to be installed.
    var onMissingData: (@MainActor () -> Void)?
    /// Audio interruption began (call, Siri...): the VM silences TTS.
    var onInterruptionBegan: (@MainActor () -> Void)?

    @MainActor private final class Lane {
        let analyzer: SpeechAnalyzer
        let transcriber: SpeechTranscriber
        let format: AVAudioFormat
        let cont: AsyncStream<AnalyzerInput>.Continuation
        var task: Task<Void, Never>?
        var cutoff = CMTime.zero // results whose audio range ends at or before this are stale
        var seenEnd = CMTime.zero // largest result range end seen (finishMine waits on it)
        init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, format: AVAudioFormat, cont: AsyncStream<AnalyzerInput>.Continuation) {
            self.analyzer = analyzer; self.transcriber = transcriber; self.format = format; self.cont = cont
        }
        func isStale(_ range: CMTimeRange) -> Bool { range.isValid && range.end <= cutoff }
        /// Force finals through `t`; whatever they produce is dropped by the cutoff.
        func flush(through t: CMTime) async {
            if t > cutoff { cutoff = t }
            try? await analyzer.finalize(through: t)
        }
    }

    private enum KoState { case idle, collecting, finalizing }
    private struct TranslateTimeout: Error {}

    private let zhHant = Locale.Language(identifier: "zh-Hant")
    private let koLang = Locale.Language(identifier: "ko")
    private let feeder = LiveMicFeeder()
    private var continuation: AsyncStream<ListenEvent>.Continuation?
    private var mode = ListenMode.paused
    private var resting = ListenMode.idle // last of .partner/.idle set by the VM
    private var running = false, starting = false
    private var startGen = 0
    private var zh: Lane?, ko: Lane?
    private var startTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var stableTask: Task<Void, Never>?
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
        let old = mode
        mode = new
        switch new {
        case .paused: teardown()
        case .partner, .idle:
            resting = new
            if new == .idle { stableTask?.cancel(); lastPartnerPartial = "" }
            if running {
                if new == .idle, old != .idle, let zh { let e = feeder.lastEnd(.zh); Task { await zh.flush(through: e) } } // drop the in-flight line
                applyMode()
            } else { startIfNeeded() }
        case .me:
            stableTask?.cancel()
            koFinals = []; koVolatile = ""; lastMyPartial = ""; koState = .collecting
            if running { applyMode() } else { startIfNeeded() }
        }
    }

    func endMine(valid: Bool) {
        guard mode == .me else { return }
        let koEnd = feeder.lastEnd(.ko)
        let released = feeder.lastVoiceDate
        mode = resting
        applyMode() // partner line resumes immediately; idle just discards audio
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

    /// App became active: audio may have been killed without an `.ended` interruption.
    func resume() {
        guard mode != .paused else { return }
        guard running else { startIfNeeded(); return }
        restartAudio(reactivate: true)
    }

    // MARK: My turn

    // ponytail: a second press while the previous one is still finalizing shares koFinals; fine for a human-speed button.
    private func finishMine(koEnd: CMTime, released: Date) async {
        guard let ko else { koState = .idle; continuation?.yield(.myFailed); return }
        try? await ko.analyzer.finalize(through: koEnd)
        let deadline = Date().addingTimeInterval(Self.finalResultWait)
        while ko.seenEnd < koEnd, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) } // results usually already in
        let text = (koFinals + [koVolatile]).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if koState == .finalizing { koState = .idle }
        if koEnd > ko.cutoff { ko.cutoff = koEnd } // late results of this turn must not leak into the next
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

    /// Races the translation against `translateTimeout`. The translation itself may ignore cancellation,
    /// so this resumes on whichever finishes first instead of waiting for both (a task group would wait).
    private func translate(_ text: String, partner: Bool) async throws -> String {
        let done = OSAllocatedUnfairLock(initialState: false)
        do {
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let finish: @Sendable (Result<String, Error>) -> Void = { r in
                    if done.withLock({ let was = $0; $0 = true; return was }) { return }
                    cont.resume(with: r)
                }
                Task { @MainActor in
                    do { finish(.success(try await self.translateOnce(text, partner: partner))) }
                    catch { finish(.failure(error)) }
                }
                Task {
                    try? await Task.sleep(for: .seconds(Self.translateTimeout))
                    finish(.failure(TranslateTimeout()))
                }
            }
        } catch let e as TranslateTimeout {
            // The session may be wedged: give the next sentence a fresh one.
            if partner { zhToKo = TranslationSession(installedSource: zhHant, target: koLang) }
            else { koToZh = TranslationSession(installedSource: koLang, target: zhHant) }
            throw e
        }
    }

    /// partner: zh→ko (serial partner worker), else ko→zh (my turn). Each direction has its own session.
    /// CancellationError (seen when another translation consumer is active) is retried once on a fresh session.
    private func translateOnce(_ text: String, partner: Bool) async throws -> String {
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

    private static func isJunk(_ t: String, voiced: TimeInterval?) -> String? {
        if !t.unicodeScalars.contains(where: { $0.properties.isUnifiedIdeograph }) { return "no Han" }
        let fillers = Set("嗯啊呃哦喔欸")
        if t.allSatisfy({ fillers.contains($0) || $0.isPunctuation || $0.isWhitespace }) { return "fillers" }
        if let voiced, voiced < minFinalDuration { return "short \(voiced)s" }
        return nil
    }

    private func handleZh(_ text: String, isFinal: Bool, range: CMTimeRange) {
        guard let lane = zh, !lane.isStale(range) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if isFinal {
            stableTask?.cancel(); lastPartnerPartial = ""
            if let why = Self.isJunk(t, voiced: range.isValid ? range.duration.seconds : nil) { log("[ENGINE] dropped junk: \(t) (\(why))"); return }
            log("[ENGINE] zh final: \(t)")
            partnerQueue?.yield((t, feeder.lastVoiceDate))
        } else if t != lastPartnerPartial {
            lastPartnerPartial = t; continuation?.yield(.partnerPartial(t))
            // Text-stability endpoint: noisy rooms may never produce enough silence.
            stableTask?.cancel()
            stableTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.textStableToFinalize))
                guard !Task.isCancelled, let self, self.mode == .partner, self.lastPartnerPartial == t, let zh = self.zh else { return }
                self.log("[ENGINE] text stable \(Self.textStableToFinalize)s → finalize")
                try? await zh.analyzer.finalize(through: self.feeder.lastEnd(.zh))
            }
        }
    }

    private func handleKo(_ text: String, isFinal: Bool, range: CMTimeRange) {
        guard let lane = ko, !lane.isStale(range), koState != .idle else { return }
        if range.isValid, range.end > lane.seenEnd { lane.seenEnd = range.end }
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
            } catch { log("[ENGINE] translate failed, sentence skipped: zh→ko \(error)") }
        }
    }

    // MARK: Lifecycle

    /// Sink for the current mode. The mic is never touched here: it runs whenever the engine is live.
    private func applyMode() {
        feeder.setSink(mode == .partner ? .zh : mode == .me ? .ko : .none)
    }

    /// Starts / revives the mic on the feeder's audio queue; returns at once. Failures hop back here and retry.
    private func ensureAudio(reactivate: Bool = false) {
        guard running, mode != .paused else { return }
        feeder.start(reactivate: reactivate) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.log("[ENGINE] audio start failed (retrying): \(error)")
                self?.scheduleAudioRetry()
            }
        }
    }

    private func scheduleAudioRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.startRetryDelay))
            guard !Task.isCancelled, let self else { return }
            self.ensureAudio()
        }
    }

    private func startIfNeeded() {
        guard !running, !starting, mode != .paused else { return }
        starting = true
        startGen += 1
        let gen = startGen
        startTask = Task {
            var retry = false
            do { try await start(gen: gen); running = true }
            catch is CancellationError {}
            catch { log("[ENGINE] start failed: \(error)"); retry = true }
            guard gen == startGen else { return } // torn down meanwhile; a newer start owns the flags
            starting = false
            if running { ensureAudio(); applyMode() }
            else if retry, mode != .paused {
                try? await Task.sleep(for: .seconds(Self.startRetryDelay))
                if gen == startGen, mode != .paused { startIfNeeded() }
            }
        }
    }

    private func start(gen: Int) async throws {
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

        let zhLane = try await makeLane(zhLoc)
        let koLane: Lane
        do { koLane = try await makeLane(koLoc) } catch { await zhLane.analyzer.cancelAndFinishNow(); throw error }
        guard gen == startGen, !Task.isCancelled else { // torn down while preparing
            zhLane.cont.finish(); koLane.cont.finish()
            await zhLane.analyzer.cancelAndFinishNow(); await koLane.analyzer.cancelAndFinishNow()
            throw CancellationError()
        }
        zhToKo = TranslationSession(installedSource: zhHant, target: koLang)
        koToZh = TranslationSession(installedSource: koLang, target: zhHant)
        zh = zhLane; ko = koLane
        zhLane.task = Task { [weak self] in
            do { for try await r in zhLane.transcriber.results { self?.handleZh(String(r.text.characters), isFinal: r.isFinal, range: r.range) } }
            catch { self?.log("[ENGINE] zh results: \(error)") }
        }
        koLane.task = Task { [weak self] in
            do { for try await r in koLane.transcriber.results { self?.handleKo(String(r.text.characters), isFinal: r.isFinal, range: r.range) } }
            catch { self?.log("[ENGINE] ko results: \(error)") }
        }
        let (q, qc) = AsyncStream.makeStream(of: (text: String, voice: Date).self)
        partnerQueue = qc
        partnerWorker = Task { await runPartnerWorker(q) }

        // Lanes only: the mic starts via ensureAudio() once running.
        feeder.configure(zh: (zhLane.cont, zhLane.format), ko: (koLane.cont, koLane.format)) { [weak self] t in
            Task { @MainActor in self?.endpoint(t) }
        }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = Self.observe(
            restart: { @MainActor [weak self] reactivate in self?.restartAudio(reactivate: reactivate) },
            began: { @MainActor [weak self] in self?.onInterruptionBegan?() })
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

    /// VAD saw speech then silence (or 8 s of voice) in partner mode: force a final through the last voiced buffer.
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
        ensureAudio(reactivate: reactivate)
    }

    private func teardown() {
        startGen += 1; starting = false
        startTask?.cancel(); startTask = nil
        retryTask?.cancel(); retryTask = nil
        stableTask?.cancel(); stableTask = nil
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
    nonisolated private static func observe(restart: @escaping @Sendable @MainActor (_ reactivate: Bool) -> Void,
                                            began: @escaping @Sendable @MainActor () -> Void) -> [NSObjectProtocol] {
        [.AVAudioEngineConfigurationChange, AVAudioSession.interruptionNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { @Sendable note in
                if name == AVAudioSession.interruptionNotification {
                    let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    if type == AVAudioSession.InterruptionType.began.rawValue { Task { @MainActor in began() } }
                    else if type == AVAudioSession.InterruptionType.ended.rawValue { Task { @MainActor in restart(true) } }
                } else {
                    Task { @MainActor in restart(false) }
                }
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
