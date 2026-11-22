#if DEBUG
import SwiftUI
import Speech
import Translation
import AVFoundation
import os

// Stage 2 feasibility probe. Reports each check on screen and as `[PROBE] name | STATUS | detail` on stdout.

struct ProbeRow: Identifiable {
    let name: String
    var status: String
    var detail: String
    var id: String { name }
}

/// Mic -> converted buffers -> AsyncStream. Not isolated: the tap runs on an audio thread.
final class MicFeeder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lastVoice = OSAllocatedUnfairLock(initialState: Date.distantPast)

    var lastVoiceTime: Date { lastVoice.withLock { $0 } }

    func start(target: AVAudioFormat, into cont: AsyncStream<AnalyzerInput>.Continuation) throws {
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard let conv = AVAudioConverter(from: inFmt, to: target) else {
            throw NSError(domain: "Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "converter \(inFmt) -> \(target)"])
        }
        converter = conv
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { @Sendable [self] buf, _ in
            handle(buf, inFmt: inFmt, target: target, cont: cont)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func handle(_ buf: AVAudioPCMBuffer, inFmt: AVAudioFormat, target: AVAudioFormat, cont: AsyncStream<AnalyzerInput>.Continuation) {
        if let ch = buf.floatChannelData?[0], buf.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
            if (sum / Float(buf.frameLength)).squareRoot() > 0.01 { lastVoice.withLock { $0 = Date() } }
        }
        guard let conv = converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / inFmt.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        let box = OSAllocatedUnfairLock(initialState: false)
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            let done = box.withLock { d -> Bool in let was = d; d = true; return was }
            if done { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            return buf
        }
        if err == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
    }
}

@MainActor @Observable
final class EngineProbe {
    var rows: [ProbeRow] = []
    var live = ""
    var running = false
    var progress: Double?
    var downloadConfig: TranslationSession.Configuration?
    private var pendingDownloads: [TranslationSession.Configuration] = []
    private let synth = AVSpeechSynthesizer()

    private let zhHant = Locale.Language(identifier: "zh-Hant")
    private let ko = Locale.Language(identifier: "ko")

    func report(_ name: String, _ status: String, _ detail: String) {
        print("[PROBE] \(name) | \(status) | \(detail)")
        if let i = rows.firstIndex(where: { $0.name == name }) { rows[i].status = status; rows[i].detail = detail }
        else { rows.append(ProbeRow(name: name, status: status, detail: detail)) }
    }

    func reprint() {
        print("[PROBE] ===== summary =====")
        for r in rows { print("[PROBE] \(r.name) | \(r.status) | \(r.detail)") }
        print("[PROBE] ===== end =====")
    }

    // MARK: status checks

    func checkAll() async {
        await checkPermissions()
        await checkSpeech()
        await checkTranslation()
        checkVoices()
        reprint()
    }

    func checkPermissions() async {
        let mic = await AVAudioApplication.requestRecordPermission()
        report("permission.mic", mic ? "PASS" : "FAIL", mic ? "granted" : "denied")
        let sp = await Self.requestSpeechAuthorization()
        report("permission.speech", sp == .authorized ? "PASS" : "FAIL", "status=\(sp.rawValue) (3=authorized)")
    }

    // Speech calls back on a background queue; keep the closure out of MainActor inference.
    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in c.resume(returning: status) }
        }
    }

    private func resolve(_ id: String) async -> (supported: Bool, installed: Bool, locale: Locale?) {
        let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id))
        guard let loc else { return (false, false, nil) }
        let inst = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == loc.identifier(.bcp47) }
        return (true, inst, loc)
    }

    func checkSpeech() async {
        let avail = SpeechTranscriber.isAvailable
        report("stt.available", avail ? "PASS" : "FAIL", "SpeechTranscriber.isAvailable=\(avail)")
        let filt: (Locale) -> Bool = { ["zh", "ko"].contains($0.language.languageCode?.identifier ?? "") }
        let sup = await SpeechTranscriber.supportedLocales.filter(filt).map { $0.identifier(.bcp47) }.sorted()
        let inst = await SpeechTranscriber.installedLocales.filter(filt).map { $0.identifier(.bcp47) }.sorted()
        report("stt.supportedLocales(zh/ko)", "INFO", sup.joined(separator: ","))
        report("stt.installedLocales(zh/ko)", "INFO", inst.joined(separator: ","))
        for id in ["zh-TW", "ko-KR", "zh-CN"] {
            let r = await resolve(id)
            let st: String
            if !r.supported { st = id == "zh-CN" ? "INFO" : "FAIL" }
            else { st = r.installed ? "PASS" : "NEEDS_DOWNLOAD" }
            report("stt.\(id)", st, "supported=\(r.supported) installed=\(r.installed) resolved=\(r.locale?.identifier(.bcp47) ?? "-")")
        }
    }

    func checkTranslation() async {
        let av = LanguageAvailability()
        var inst: [String: Bool] = [:]
        for (n, s, t) in [("zhHant->ko", zhHant, ko), ("ko->zhHant", ko, zhHant)] {
            let st = await av.status(from: s, to: t)
            inst[n] = st == .installed
            let (label, status): (String, String) = switch st {
            case .installed: ("installed", "PASS")
            case .supported: ("supported (not downloaded)", "NEEDS_DOWNLOAD")
            case .unsupported: ("unsupported", "FAIL")
            @unknown default: ("unknown", "FAIL")
            }
            report("tr.status.\(n)", status, label)
        }
        if inst["zhHant->ko"] == true { await translateSample("tr.sample.zhHant->ko", "請問洗手間在哪裡？", zhHant, ko) }
        if inst["ko->zhHant"] == true { await translateSample("tr.sample.ko->zhHant", "화장실이 어디예요?", ko, zhHant) }
    }

    private func translateSample(_ name: String, _ text: String, _ s: Locale.Language, _ t: Locale.Language) async {
        let session = TranslationSession(installedSource: s, target: t)
        let t0 = Date()
        do {
            let r = try await session.translate(text)
            report(name, "PASS", "\(text) -> \(r.targetText) (\(Int(Date().timeIntervalSince(t0) * 1000))ms)")
        } catch { report(name, "FAIL", "\(error)") }
    }

    func checkVoices() {
        let vs = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "ko-KR" }
        for v in vs { print("[PROBE] tts.voice | INFO | \(v.name) \(v.identifier) q=\(qName(v.quality))") }
        let good = vs.contains { $0.quality.rawValue >= AVSpeechSynthesisVoiceQuality.enhanced.rawValue }
        let list = vs.map { "\($0.name)(\(qName($0.quality)))" }.joined(separator: ", ")
        report("tts.ko-KR", good ? "PASS" : "NEEDS_DOWNLOAD",
               good ? list : "고품질 음성 없음 [\(list)] 설정 → 손쉬운 사용 → 읽기 및 말하기 → 음성 → 한국어")
    }

    private func qName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q { case .default: "default"; case .enhanced: "enhanced"; case .premium: "premium"; @unknown default: "?" }
    }

    func speakKorean() {
        let best = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "ko-KR" }.max { $0.quality.rawValue < $1.quality.rawValue }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { report("tts.speak", "FAIL", "session \(error)") }
        let u = AVSpeechUtterance(string: "화장실은 저쪽에 있어요.")
        u.voice = best ?? AVSpeechSynthesisVoice(language: "ko-KR")
        synth.speak(u)
        report("tts.speak", "INFO", "voice=\(best?.name ?? "default") q=\(best.map { qName($0.quality) } ?? "-")")
    }

    // MARK: downloads

    func downloadSpeech(_ id: String) async {
        let r = await resolve(id)
        guard let loc = r.locale else { report("stt.download.\(id)", "FAIL", "unsupported"); return }
        let tr = SpeechTranscriber(locale: loc, preset: .transcription)
        do {
            guard let req = try await AssetInventory.assetInstallationRequest(supporting: [tr]) else {
                report("stt.download.\(id)", "PASS", "nothing to install"); await checkSpeech(); return
            }
            let p = req.progress
            let poll = Task { while !Task.isCancelled { progress = p.fractionCompleted; try? await Task.sleep(for: .milliseconds(300)) } }
            try await req.downloadAndInstall()
            poll.cancel(); progress = nil
            report("stt.download.\(id)", "PASS", "installed")
        } catch { progress = nil; report("stt.download.\(id)", "FAIL", "\(error)") }
        await checkSpeech()
    }

    func startTranslationDownload() {
        pendingDownloads = [.init(source: zhHant, target: ko), .init(source: ko, target: zhHant)]
        downloadConfig = pendingDownloads.removeFirst()
    }

    func translationPrepared(ok: Bool, error: String?) async {
        report("tr.download", ok ? "PASS" : "FAIL", error ?? "prepared")
        downloadConfig = pendingDownloads.isEmpty ? nil : pendingDownloads.removeFirst()
        if downloadConfig == nil { await checkTranslation(); reprint() }
    }

    // MARK: live recognition

    func liveTest(_ id: String) async {
        guard !running else { return }
        running = true; live = ""
        defer { running = false }
        let name = "stt.live.\(id)"
        let r = await resolve(id)
        guard let loc = r.locale, r.installed else { report(name, r.supported ? "NEEDS_DOWNLOAD" : "FAIL", "locale not installed"); return }
        let feeder = MicFeeder()
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default, options: [])
            try s.setActive(true)
            let tr = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [tr]) else {
                report(name, "FAIL", "no audio format"); return
            }
            let analyzer = SpeechAnalyzer(modules: [tr])
            let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let t0 = Date()
            let results = Task { [weak self] in
                do {
                    for try await res in tr.results {
                        let text = String(res.text.characters)
                        let final = res.isFinal
                        let lat = Date().timeIntervalSince(feeder.lastVoiceTime)
                        self?.onResult(name: name, text: text, final: final, latency: lat, since: Date().timeIntervalSince(t0))
                    }
                } catch { self?.report(name, "FAIL", "results \(error)") }
            }
            try await analyzer.start(inputSequence: stream)
            try feeder.start(target: fmt, into: cont)
            report(name, "INFO", "listening 10s, format=\(fmt.sampleRate)Hz ch=\(fmt.channelCount) — 말하세요")
            try await Task.sleep(for: .seconds(10))
            feeder.stop(); cont.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await results.value
            report(name, "PASS", "finished; last final text: \(live)")
        } catch { feeder.stop(); report(name, "FAIL", "\(error)") }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func onResult(name: String, text: String, final: Bool, latency: Double, since: Double) {
        live = (final ? "[final] " : "[volatile] ") + text
        print("[PROBE] \(name) | \(final ? "FINAL" : "VOLATILE") | t=\(String(format: "%.1f", since))s sinceLastVoice=\(String(format: "%.2f", latency))s text=\(text)")
    }
}

struct EngineProbeView: View {
    var autoRun = false
    @State private var p = EngineProbe()

    var body: some View {
        NavigationStack {
            List {
                Section("점검 결과") {
                    ForEach(p.rows) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(r.name)  \(r.status)").font(.caption.bold().monospaced())
                                .foregroundStyle(r.status == "PASS" ? .green : r.status == "FAIL" ? .red : r.status == "NEEDS_DOWNLOAD" ? .orange : .secondary)
                            Text(r.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("실시간") { Text(p.live.isEmpty ? "-" : p.live) }
                if let f = p.progress { Section { ProgressView(value: f) } }
                Section("동작") {
                    Button("모두 다시 점검") { Task { await p.checkAll() } }
                    Button("zh-TW 인식 테스트") { Task { await p.liveTest("zh-TW") } }.disabled(p.running)
                    Button("ko-KR 인식 테스트") { Task { await p.liveTest("ko-KR") } }.disabled(p.running)
                    Button("zh-TW 음성 데이터 다운로드") { Task { await p.downloadSpeech("zh-TW") } }
                    Button("ko-KR 음성 데이터 다운로드") { Task { await p.downloadSpeech("ko-KR") } }
                    Button("번역 데이터 다운로드") { p.startTranslationDownload() }
                    Button("한국어 음성 테스트") { p.speakKorean() }
                }
            }
            .navigationTitle("엔진 점검")
            .navigationBarTitleDisplayMode(.inline)
        }
        .translationTask(p.downloadConfig) { session in
            nonisolated(unsafe) let s = session // SDK hands a MainActor session to a @concurrent method; probe-only escape hatch
            do { try await s.prepareTranslation(); await p.translationPrepared(ok: true, error: nil) }
            catch { await p.translationPrepared(ok: false, error: "\(error)") }
        }
        .task { if autoRun { await p.checkAll() } }
    }
}
#endif
