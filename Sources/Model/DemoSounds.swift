import AppKit

/// The unit's own beeps, recorded from a real LG air conditioner, played only in the
/// demonstration so it feels like controlling the appliance. With a connected unit
/// the air conditioner beeps by itself, so the app stays silent.
@MainActor
enum DemoSounds {
    enum Cue: String {
        case powerOn = "power-on"
        case powerOff = "power-off"
        case adjust

        /// Playback volume. The files share the same measured level, but the adjust
        /// beep is higher pitched (~2.4 kHz vs ~2 kHz) and plays far more often, so it
        /// sounds louder; it is played about 7 dB softer to match by ear.
        var volume: Float {
            switch self {
            case .powerOn, .powerOff: return 0.6
            case .adjust: return 0.27
            }
        }
    }

    private static var cache: [Cue: NSSound] = [:]

    static func play(_ cue: Cue) {
        guard let sound = sound(for: cue) else { return }
        // Restart rather than overlap when the same cue fires again quickly.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    private static func sound(for cue: Cue) -> NSSound? {
        if let cached = cache[cue] { return cached }
        guard let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "m4a"),
              let sound = NSSound(contentsOf: url, byReference: true) else { return nil }
        sound.volume = cue.volume
        cache[cue] = sound
        return sound
    }
}
