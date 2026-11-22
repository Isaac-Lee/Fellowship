import AVFoundation

/// Shared audio session setup: play-and-record, no Bluetooth, wired mic first with built-in fallback.
enum AudioSessionSetup {
    static func activate() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [])
        try s.setActive(true)
        #if DEBUG
        print("[AUDIO] activate")
        #endif
        applyPreferredInput()
    }

    /// Wired headset/USB mic if present; nil clears the preference (built-in mic).
    static func applyPreferredInput() {
        let s = AVAudioSession.sharedInstance()
        let wired = s.availableInputs?.first { $0.portType == .headsetMic || $0.portType == .usbAudio }
        guard wired?.uid != s.preferredInput?.uid else { return } // no-op: setting it again can itself trigger a route change
        try? s.setPreferredInput(wired)
    }
}

/// Reports whether wired earphones are the output. Bluetooth/AirPlay/car outputs never count.
/// Acts only on real state changes: setPreferredInput itself posts route changes, so reacting to every one looped forever.
@MainActor
final class AudioRouteMonitor {
    private let onChange: @MainActor (Bool) -> Void
    private var token: NSObjectProtocol?
    private var lastWired: Bool
    private var lastInputUID: String?
    private var lastLog = Date.distantPast

    init(onChange: @escaping @MainActor (_ wiredConnected: Bool) -> Void) {
        self.onChange = onChange
        lastWired = Self.wiredConnected()
        lastInputUID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
        // Observer is created in a nonisolated context: the notification arrives on an arbitrary thread.
        token = Self.observe { @MainActor [weak self] reason, prev in self?.handle(reason: reason, prev: prev) }
        onChange(lastWired)
    }

    private func handle(reason: UInt, prev: String) {
        let route = AVAudioSession.sharedInstance().currentRoute
        let wired = Self.wiredConnected()
        let uid = route.inputs.first?.uid
        let changed = wired != lastWired || uid != lastInputUID
        #if DEBUG
        if changed || Date().timeIntervalSince(lastLog) >= 1 {
            lastLog = Date()
            let fmt = { (p: [AVAudioSessionPortDescription]) in p.map { "\($0.portType.rawValue)(\($0.portName))" }.joined(separator: ",") }
            print("[AUDIO] route change reason=\(reason) wired=\(wired) changed=\(changed) prev=[\(prev)] in=[\(fmt(route.inputs))] out=[\(fmt(route.outputs))]")
        }
        #endif
        guard changed else { return }
        let connected = wired && !lastWired
        let wiredChanged = wired != lastWired
        lastWired = wired; lastInputUID = uid
        if connected { AudioSessionSetup.applyPreferredInput() } // once per connect; its own route change lands as "unchanged" or a uid-only change
        if wiredChanged { onChange(wired) }
    }

    static func wiredConnected() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .headphones || $0.portType == .usbAudio || $0.portType == .lineOut
        }
    }

    nonisolated private static func observe(_ hop: @escaping @Sendable @MainActor (_ reason: UInt, _ prev: String) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { @Sendable note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let prevRoute = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            let prev = ((prevRoute?.inputs ?? []) + (prevRoute?.outputs ?? [])).map { $0.portType.rawValue }.joined(separator: ",")
            Task { @MainActor in hop(reason, prev) }
        }
    }
}
