import AVFoundation

/// Speaks Korean through AVSpeechSynthesizer. The VM owns queue and rate; this speaks one utterance at a time.
@MainActor
final class SpeechSynthesizerOutput: NSObject, SpeechOutput, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var current: (id: ObjectIdentifier, onFinish: @MainActor () -> Void)?

    override init() {
        super.init()
        synth.usesApplicationAudioSession = true
        synth.delegate = self
    }

    /// Best installed ko-KR voice: premium > enhanced > default.
    static func bestKoreanVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "ko-KR" }.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "ko-KR")
    }

    func speak(_ text: String, rate: Float, onFinish: @escaping @MainActor () -> Void) {
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.bestKoreanVoice()
        u.rate = rate
        current = (ObjectIdentifier(u), onFinish)
        synth.speak(u)
    }

    func stopImmediately() {
        current = nil // suppresses onFinish
        synth.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let c = current, c.id == id else { return }
            current = nil
            c.onFinish()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in if current?.id == id { current = nil } } // no onFinish
    }
}
