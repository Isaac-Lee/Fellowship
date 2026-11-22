import AVFoundation

/// Speaks Korean through AVSpeechSynthesizer. The VM owns queue and rate; this speaks one utterance at a time.
@MainActor
final class SpeechSynthesizerOutput: NSObject, SpeechOutput, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var current: (u: AVSpeechUtterance, onFinish: @MainActor () -> Void)?
    private var voice: AVSpeechSynthesisVoice?
    private var watchdog: Task<Void, Never>?

    override init() {
        voice = Self.bestKoreanVoice()
        super.init()
        synth.usesApplicationAudioSession = true
        synth.delegate = self
    }

    /// Best installed ko-KR voice: premium > enhanced > default.
    static func bestKoreanVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "ko-KR" }.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "ko-KR")
    }

    /// Call when the app becomes active: the user may have downloaded a better voice.
    func refreshVoice() { voice = Self.bestKoreanVoice() }

    func speak(_ text: String, rate: Float, onFinish: @escaping @MainActor () -> Void) {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        current = (u, onFinish)
        synth.speak(u)
        // Watchdog: a lost didFinish (interruption, route change) must not stall the queue forever.
        let limit = Double(text.count) * 0.25 / max(Double(rate) / 0.5, 0.5) + 3
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled, let self, self.current?.u === u else { return }
            let c = self.current
            self.current = nil
            self.synth.stopSpeaking(at: .immediate) // didCancel finds no match
            c?.onFinish()
        }
    }

    func stopImmediately() {
        watchdog?.cancel()
        current = nil // suppresses onFinish
        synth.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        nonisolated(unsafe) let u = utterance
        Task { @MainActor in
            guard let c = current, c.u === u else { return }
            current = nil
            watchdog?.cancel()
            c.onFinish()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        nonisolated(unsafe) let u = utterance
        Task { @MainActor in if current?.u === u { current = nil; watchdog?.cancel() } } // no onFinish
    }
}
