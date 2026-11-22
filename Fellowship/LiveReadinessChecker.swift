import AVFoundation
import Observation
import Speech
import Translation

/// Real permission / model / voice checks. `readyKinds()` is served from a cache that `refresh()` recomputes.
@Observable @MainActor
final class LiveReadinessChecker: ReadinessChecker {
    /// SetupView feeds this to `.translationTask`; nil when idle.
    var translationRequest: TranslationSession.Configuration?
    var showVoiceHelp = false

    @ObservationIgnored private var cache: Set<ReadinessKind>
    @ObservationIgnored private var pendingTranslation: [TranslationSession.Configuration] = []
    @ObservationIgnored private var translationDone: CheckedContinuation<Void, Never>?

    private static let zhHant = Locale.Language(identifier: "zh-Hant")
    private static let ko = Locale.Language(identifier: "ko")

    init() {
        // Async checks (models) are unknown until refresh(); trust the last completed setup to avoid a launch flash.
        var c = Self.syncKinds()
        if UserDefaults.standard.bool(forKey: "hasCompletedSetup") { c.formUnion([.zhModel, .translation]) }
        cache = c
    }

    func readyKinds() -> Set<ReadinessKind> { cache }

    private static func syncKinds() -> Set<ReadinessKind> {
        var s = Set<ReadinessKind>()
        if AVAudioApplication.shared.recordPermission == .granted { s.insert(.microphone) }
        if SFSpeechRecognizer.authorizationStatus() == .authorized { s.insert(.speechPermission) }
        if AVSpeechSynthesisVoice.speechVoices().contains(where: { $0.language == "ko-KR" && $0.quality.rawValue >= AVSpeechSynthesisVoiceQuality.enhanced.rawValue }) {
            s.insert(.koVoice)
        }
        return s
    }

    func refresh() async {
        var s = Self.syncKinds()
        if await Self.speechModelsInstalled() { s.insert(.zhModel) }
        if await Self.translationInstalled() { s.insert(.translation) }
        cache = s
    }

    private static func speechModelsInstalled() async -> Bool {
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        for id in ["zh-TW", "ko-KR"] {
            guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)),
                  installed.contains(loc.identifier(.bcp47)) else { return false }
        }
        return true
    }

    private static func translationInstalled() async -> Bool {
        let av = LanguageAvailability()
        let a = await av.status(from: zhHant, to: ko)
        let b = await av.status(from: ko, to: zhHant)
        return a == .installed && b == .installed
    }

    func prepare(_ kind: ReadinessKind) async {
        switch kind {
        case .microphone: _ = await AVAudioApplication.requestRecordPermission()
        case .speechPermission: _ = await Self.requestSpeechAuthorization()
        case .zhModel: await installSpeechModels()
        case .translation: await prepareTranslation()
        case .koVoice: showVoiceHelp = true // cannot be downloaded programmatically
        }
        await refresh()
    }

    // Speech calls back on a background queue; keep the closure out of MainActor inference.
    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in c.resume(returning: status) }
        }
    }

    private func installSpeechModels() async {
        for id in ["zh-TW", "ko-KR"] {
            guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else { continue }
            let tr = SpeechTranscriber(locale: loc, preset: .transcription)
            do { try await AssetInventory.assetInstallationRequest(supporting: [tr])?.downloadAndInstall() }
            catch { print("speech model install failed \(id): \(error)") }
        }
    }

    // MARK: translation (driven by SetupView's .translationTask)

    private func prepareTranslation() async {
        pendingTranslation = [.init(source: Self.zhHant, target: Self.ko), .init(source: Self.ko, target: Self.zhHant)]
        translationRequest = pendingTranslation.removeFirst()
        await withCheckedContinuation { translationDone = $0 }
    }

    /// Called by SetupView after each configuration's prepareTranslation() finishes (or fails).
    func translationPrepared(ok: Bool) {
        if !ok { pendingTranslation.removeAll() }
        translationRequest = pendingTranslation.isEmpty ? nil : pendingTranslation.removeFirst()
        if translationRequest == nil { translationDone?.resume(); translationDone = nil }
    }
}
