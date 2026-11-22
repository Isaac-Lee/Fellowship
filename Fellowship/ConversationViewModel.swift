import Foundation
import Observation
import Translation

enum Speaker { case partner, me }

struct Message: Identifiable, Hashable {
    let id = UUID()
    let speaker: Speaker
    let original: String
    let translation: String
}

enum ReadinessKind: Int, CaseIterable, Identifiable {
    case microphone, speechPermission, zhModel, translation, koVoice
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .microphone: "마이크 권한"
        case .speechPermission: "음성 인식 권한"
        case .zhModel: "중국어(대만) 인식 모델"
        case .translation: "중국어↔한국어 번역 데이터"
        case .koVoice: "한국어 음성"
        }
    }
}

struct ReadinessItem: Identifiable {
    let kind: ReadinessKind
    var id: ReadinessKind { kind }
    var isReady = false
    var isDownloading = false
}

extension Array where Element == ReadinessItem {
    /// Items are built in `ReadinessKind.allCases` order.
    subscript(kind kind: ReadinessKind) -> ReadinessItem {
        get { self[kind.rawValue] }
        set { self[kind.rawValue] = newValue }
    }
}

/// Single state holder. Fake behavior lives in MockConversationEngine; stage 2 swaps the engines.
@Observable @MainActor
final class ConversationViewModel {
    // MARK: Setup
    var readiness = ReadinessKind.allCases.map { ReadinessItem(kind: $0) }
    var allReady: Bool { readiness.allSatisfy(\.isReady) }
    var hasCompletedSetup: Bool = UserDefaults.standard.bool(forKey: "hasCompletedSetup") {
        didSet { UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup") }
    }
    var showSetup: Bool { !hasCompletedSetup || !allReady }

    // MARK: Conversation
    var messages: [Message] = []
    var partnerPartial: String?
    var isHoldingToTalk = false
    var myPartial = ""
    var retryHint = false
    var showCard: Message?
    var successCount = 0 // haptic trigger

    // MARK: Audio state
    var earphonesConnected = true
    var showUnpluggedBanner = false // set only by an unplug event
    var voiceEnabled = true {
        didSet { if !voiceEnabled { silence() } }
    }
    #if DEBUG
    /// Test aid: speak through the loud speaker without earphones. Never persisted; off on every launch.
    var speakerTestMode = false { didSet { applySpeakerOverride() } }
    #endif
    var speakQueue: [String] = []
    var pendingSpeechCount: Int { speakQueue.count }
    var speechRate: Float { Self.rate(forQueueLength: speakQueue.count) }

    @ObservationIgnored private let listening: ListeningEngine
    @ObservationIgnored private let checker: ReadinessChecker
    @ObservationIgnored private let speech: SpeechOutput
    @ObservationIgnored private var pressStart: Date?
    @ObservationIgnored private var isTranslating = false
    @ObservationIgnored private var isSpeaking = false
    @ObservationIgnored private var speechGeneration = 0
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var routeMonitor: AudioRouteMonitor?
    @ObservationIgnored private var routeKnown = false

    init(listening: ListeningEngine, checker: ReadinessChecker, speech: SpeechOutput) {
        self.listening = listening
        self.checker = checker
        self.speech = speech
        refreshReadiness()
    }

    convenience init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-mock") {
            let mock = MockConversationEngine()
            self.init(listening: mock, checker: mock, speech: MockSpeaker())
            return
        }
        #endif
        let engine = LiveListeningEngine()
        self.init(listening: engine, checker: LiveReadinessChecker(), speech: SpeechSynthesizerOutput())
        engine.onMissingData = { [weak self] in self?.refreshReadiness() }
        routeMonitor = AudioRouteMonitor { [weak self] connected in self?.routeChanged(connected: connected) }
    }

    /// All-mock VM for SwiftUI previews.
    static func preview() -> ConversationViewModel {
        let mock = MockConversationEngine()
        return ConversationViewModel(listening: mock, checker: mock, speech: MockSpeaker())
    }

    // Live-checker hooks for SetupView (nil/false with mocks).
    private var live: LiveReadinessChecker? { checker as? LiveReadinessChecker }
    var translationRequest: TranslationSession.Configuration? { live?.translationRequest }
    func translationPrepared(ok: Bool) { live?.translationPrepared(ok: ok) }
    var showVoiceHelp: Bool {
        get { live?.showVoiceHelp ?? false }
        set { live?.showVoiceHelp = newValue }
    }

    // MARK: Pure rules (unit-testable in stage 2)
    static let minimumPress: TimeInterval = 0.5
    static func isValidPress(duration: TimeInterval) -> Bool { duration >= minimumPress }
    /// 1.0x-equivalent normal rate 0.5 (AVSpeechUtteranceDefaultSpeechRate); faster when sentences pile up.
    static func rate(forQueueLength n: Int) -> Float { n > 1 ? min(0.5 + 0.05 * Float(n - 1), 0.62) : 0.5 }

    // MARK: Setup actions
    /// Called at launch and when the app becomes active; stage 2 detects missing data here.
    func refreshReadiness() {
        apply(checker.readyKinds()) // cached value now, fresh value after refresh()
        Task {
            await checker.refresh()
            apply(checker.readyKinds())
            if hasCompletedSetup && !allReady { hasCompletedSetup = false } // data went missing: re-confirm
        }
    }
    private func apply(_ ready: Set<ReadinessKind>) {
        for kind in ReadinessKind.allCases { readiness[kind: kind].isReady = ready.contains(kind) }
    }
    func download(_ item: ReadinessItem) {
        guard !readiness[kind: item.kind].isDownloading else { return }
        readiness[kind: item.kind].isDownloading = true
        Task {
            await checker.prepare(item.kind)
            readiness[kind: item.kind].isDownloading = false
            apply(checker.readyKinds())
        }
    }
    func completeSetup() { if allReady { hasCompletedSetup = true } }

    // MARK: Press to talk
    func pressBegan() {
        guard !isHoldingToTalk, !isTranslating else { return }
        pressStart = Date()
        isHoldingToTalk = true
        retryHint = false
        myPartial = ""
        listening.setMode(.me) // partner line pauses, partnerPartial stays
    }

    func pressEnded() {
        guard isHoldingToTalk else { return }
        isHoldingToTalk = false
        let valid = Self.isValidPress(duration: Date().timeIntervalSince(pressStart ?? .now))
        if valid { partnerPartial = nil; isTranslating = true } else { myPartial = "" }
        listening.endMine(valid: valid)
    }

    /// Press interrupted (backgrounding etc.): reset without translating.
    func cancelPress() {
        guard isHoldingToTalk else { return }
        isHoldingToTalk = false
        myPartial = ""
        listening.endMine(valid: false)
    }

    private func showRetryHint() {
        retryHint = true
        retryTask?.cancel()
        retryTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { retryHint = false }
        }
    }

    // MARK: Engine events
    func start() {
        guard eventsTask == nil else { return }
        let stream = listening.events()
        eventsTask = Task { for await e in stream { handle(e) } }
        listening.setMode(.partner)
    }

    func stop() {
        eventsTask?.cancel(); eventsTask = nil
        retryTask?.cancel()
        listening.setMode(.paused)
        silence()
        partnerPartial = nil
        myPartial = ""
        isHoldingToTalk = false
        isTranslating = false
    }

    func handle(_ event: ListenEvent) {
        switch event {
        case .partnerPartial(let s): if partnerPartial != s { partnerPartial = s }
        case .partnerFinal(let zh, let ko):
            partnerPartial = nil
            messages.append(Message(speaker: .partner, original: zh, translation: ko))
            enqueueSpeech(ko)
        case .myPartial(let s): if isHoldingToTalk, myPartial != s { myPartial = s }
        case .myFinal(let ko, let zh):
            isTranslating = false
            myPartial = ""
            let m = Message(speaker: .me, original: ko, translation: zh)
            messages.append(m)
            successCount += 1
            showCard = m
        case .myFailed:
            isTranslating = false
            myPartial = ""
            showRetryHint()
        }
    }

    // MARK: Speech queue (VM owns queue + rate; the engine speaks one utterance)
    func replay(_ message: Message) { enqueueSpeech(message.translation) }

    private func enqueueSpeech(_ text: String) {
        #if DEBUG
        let allowed = earphonesConnected || speakerTestMode
        #else
        let allowed = earphonesConnected
        #endif
        guard voiceEnabled && allowed else { return }
        speakQueue.append(text)
        speakNext()
    }

    private func speakNext() {
        guard !isSpeaking, let text = speakQueue.first else { return }
        isSpeaking = true
        let generation = speechGeneration
        speech.speak(text, rate: speechRate) { [weak self] in
            guard let self, generation == speechGeneration else { return }
            isSpeaking = false
            speakQueue.removeFirst()
            speakNext()
        }
    }

    private func silence() {
        speechGeneration += 1
        isSpeaking = false
        speakQueue.removeAll()
        speech.stopImmediately()
    }

    /// Monitor entry point: the first report is the launch state (no banner), later ones are changes.
    private func routeChanged(connected: Bool) {
        if routeKnown { earphonesDidChange(connected: connected) } else { earphonesConnected = connected; routeKnown = true }
    }

    /// Route-change entry point (stage 2: AVAudioSession). Unplug silences; sentences after replug are spoken.
    func earphonesDidChange(connected: Bool) {
        earphonesConnected = connected
        showUnpluggedBanner = !connected
        if !connected { silence() }
        #if DEBUG
        applySpeakerOverride()
        #endif
    }

    #if DEBUG
    /// Speaker only while test mode is on and no earphones; the override emits .override route changes, which the monitor ignores (wired/input unchanged).
    private func applySpeakerOverride() { AudioSessionSetup.setSpeakerOverride(speakerTestMode && !earphonesConnected) }
    private var mock: MockConversationEngine? { listening as? MockConversationEngine }
    func simulateUnplug() { earphonesDidChange(connected: false) }
    func simulateReplug() { earphonesDidChange(connected: true) }
    func simulateRecognitionFailure() { mock?.failNextRecognition = true }
    func simulateMissingLanguageData() {
        mock?.ready.remove(.translation)
        hasCompletedSetup = false
        refreshReadiness()
    }
    func simulateBacklog() { for l in MockConversationEngine.partnerLines.prefix(4) { enqueueSpeech(l.ko) } }
    func resetSetup() {
        stop()
        hasCompletedSetup = false
        mock?.ready = []
        for kind in ReadinessKind.allCases { readiness[kind: kind].isDownloading = false }
        refreshReadiness()
    }
    #endif
}
