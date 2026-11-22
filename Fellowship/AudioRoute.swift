import AVFoundation

/// Shared audio session setup: play-and-record, no Bluetooth, wired mic first with built-in fallback.
enum AudioSessionSetup {
    static func activate() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [])
        try s.setActive(true)
        applyPreferredInput()
    }

    /// Wired headset/USB mic if present; nil clears the preference (built-in mic).
    static func applyPreferredInput() {
        let s = AVAudioSession.sharedInstance()
        let wired = s.availableInputs?.first { $0.portType == .headsetMic || $0.portType == .usbAudio }
        try? s.setPreferredInput(wired)
    }
}

/// Reports whether wired earphones are the output. Bluetooth/AirPlay/car outputs never count.
@MainActor
final class AudioRouteMonitor {
    private let onChange: @MainActor (Bool) -> Void
    private var token: NSObjectProtocol?

    init(onChange: @escaping @MainActor (_ wiredConnected: Bool) -> Void) {
        self.onChange = onChange
        // Observer is created in a nonisolated context: the notification arrives on an arbitrary thread.
        token = Self.observe { @MainActor [weak self] in
            AudioSessionSetup.applyPreferredInput()
            self?.onChange(Self.wiredConnected())
        }
        onChange(Self.wiredConnected())
    }

    static func wiredConnected() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .headphones || $0.portType == .usbAudio || $0.portType == .lineOut
        }
    }

    nonisolated private static func observe(_ hop: @escaping @Sendable @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { @Sendable _ in
            Task { @MainActor in hop() }
        }
    }
}
