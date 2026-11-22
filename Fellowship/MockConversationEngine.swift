import Foundation

// MARK: - Engine contracts (stage 2 supplies real implementations)

enum ListenMode { case partner /* zh-TW */, me /* ko-KR */, paused }

enum ListenEvent: Sendable {
    case partnerPartial(String)
    case partnerFinal(zh: String, ko: String)
    case myPartial(String)
    case myFinal(ko: String, zh: String)
    case myFailed
}

@MainActor
protocol ListeningEngine {
    /// One stream per start(); call again after setMode(.paused) to restart.
    func events() -> AsyncStream<ListenEvent>
    /// .partner: listen to partner (resumes a paused line). .me: pause the partner line, recognise my speech.
    /// .paused: stop everything and drop in-flight lines.
    func setMode(_ mode: ListenMode)
    /// Button released. Invalid press: discard my speech, resume the paused partner line.
    /// Valid: drop the partner line, translate, then emit myFinal or myFailed; back to partner mode.
    func endMine(valid: Bool)
}

@MainActor
protocol SpeechOutput {
    /// Speaks one utterance; the VM owns the queue and the rate. A stopImmediately() must suppress onFinish.
    func speak(_ text: String, rate: Float, onFinish: @escaping @MainActor () -> Void)
    func stopImmediately()
}

@MainActor
protocol ReadinessChecker {
    func readyKinds() -> Set<ReadinessKind>
    func prepare(_ kind: ReadinessKind) async
}

// MARK: - Mock implementations

@MainActor
final class MockConversationEngine: ListeningEngine, ReadinessChecker {
    private var continuation: AsyncStream<ListenEvent>.Continuation?
    private var mode = ListenMode.paused
    private var partnerTask: Task<Void, Never>?
    private var myTask: Task<Void, Never>?
    private var line: (zh: String, ko: String)? // partner line in progress
    private var shown = 0
    private var idleTicks = 25
    private var lineIndex = 0, sampleIndex = 0
    private var myShown = 0

    // Readiness (persisted flag stands in for real permission/model checks).
    var ready: Set<ReadinessKind> = UserDefaults.standard.bool(forKey: "hasCompletedSetup") ? Set(ReadinessKind.allCases) : []
    func readyKinds() -> Set<ReadinessKind> { ready }
    func prepare(_ kind: ReadinessKind) async {
        try? await Task.sleep(for: .seconds(1))
        ready.insert(kind)
    }

    func events() -> AsyncStream<ListenEvent> {
        let (stream, c) = AsyncStream.makeStream(of: ListenEvent.self)
        continuation = c
        return stream
    }

    func setMode(_ new: ListenMode) {
        mode = new
        switch new {
        case .partner:
            if partnerTask == nil { partnerTask = Task { await runPartner() } }
        case .me:
            let sample = Self.mySamples[sampleIndex % Self.mySamples.count]
            myShown = 0
            myTask = Task {
                for i in 1...sample.ko.count {
                    try? await Task.sleep(for: .seconds(0.09))
                    if Task.isCancelled { return }
                    myShown = i
                    continuation?.yield(.myPartial(String(sample.ko.prefix(i))))
                }
            }
        case .paused:
            partnerTask?.cancel(); partnerTask = nil
            myTask?.cancel(); myTask = nil
            line = nil; idleTicks = 25
        }
    }

    func endMine(valid: Bool) {
        myTask?.cancel()
        mode = .partner
        guard valid else { return } // partner line resumes where it stopped
        line = nil; idleTicks = 25
        let sample = Self.mySamples[sampleIndex % Self.mySamples.count]
        let fail = failNextRecognition || myShown == 0
        failNextRecognition = false
        myTask = Task {
            try? await Task.sleep(for: .seconds(0.6)) // fake translation latency
            if Task.isCancelled { return }
            if fail { continuation?.yield(.myFailed); return }
            sampleIndex += 1
            continuation?.yield(.myFinal(ko: sample.ko, zh: sample.zh))
        }
    }

    private func runPartner() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(120))
            guard mode == .partner else { continue } // paused by the talk button: keep line as is
            if idleTicks > 0 { idleTicks -= 1; continue }
            if line == nil { line = Self.partnerLines[lineIndex % Self.partnerLines.count]; lineIndex += 1; shown = 0 }
            guard let l = line else { continue }
            shown += 1
            continuation?.yield(.partnerPartial(String(l.zh.prefix(shown))))
            if shown >= l.zh.count {
                continuation?.yield(.partnerFinal(zh: l.zh, ko: l.ko))
                line = nil; idleTicks = 67
            }
        }
    }

    static let partnerLines: [(zh: String, ko: String)] = [
        ("歡迎光臨！請問幾位？", "어서 오세요! 몇 분이세요?"),
        ("這邊請，菜單在桌上。", "이쪽으로 오세요. 메뉴는 테이블 위에 있어요."),
        ("請問要點什麼？", "무엇을 주문하시겠어요?"),
        ("我們的招牌是牛肉麵，很好吃。", "저희 대표 메뉴는 우육면인데, 아주 맛있어요."),
        ("要不要加辣？", "맵게 해 드릴까요?"),
        ("一共三百二十元，可以刷卡。", "총 320위안이고, 카드 결제 가능합니다."),
    ]
    static let mySamples: [(ko: String, zh: String)] = [
        ("화장실이 어디예요?", "請問洗手間在哪裡？"),
        ("이거 하나 주세요.", "請給我一份這個。"),
        ("너무 맵지 않게 해 주세요.", "請不要太辣。"),
        ("계산해 주세요.", "請幫我結帳。"),
    ]

    #if DEBUG
    var failNextRecognition = false
    #else
    private let failNextRecognition = false
    #endif
}

/// Fake speaker: each utterance takes 2.5s.
@MainActor
final class MockSpeaker: SpeechOutput {
    private var task: Task<Void, Never>?
    func speak(_ text: String, rate: Float, onFinish: @escaping @MainActor () -> Void) {
        task = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { onFinish() }
        }
    }
    func stopImmediately() { task?.cancel(); task = nil }
}
