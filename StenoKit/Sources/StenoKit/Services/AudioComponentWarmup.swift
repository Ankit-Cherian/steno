#if os(macOS)
import AudioToolbox
import Foundation

/// Loads Core Audio's list of audio components ahead of the first recording.
///
/// The first recording in a process looks up audio components, and that lookup waits for the
/// system's AudioComponentRegistrar. When the registrar is not running it is launched and scans
/// for components first, which was measured at 1.6 s; the recorder setup that triggered it ran
/// on the main thread and blocked it for 1.8 s before any audio was captured. Asking for the
/// component list once at launch, off the main thread, pays that cost before anyone presses a
/// key. It reads a list only: it opens no audio device, starts no input and needs no microphone
/// permission.
public enum AudioComponentWarmup {
    /// Runs `lookup` once on a background task and returns how long it took.
    public static func run(
        lookup: @escaping @Sendable () -> Void = loadComponents
    ) async -> Duration {
        await Task.detached(priority: .userInitiated) {
            ContinuousClock().measure(lookup)
        }.value
    }

    /// Fetches the component list, then finds the audio file component a recording writes with,
    /// which is the first search recorder setup makes (measured at about 5 ms more when skipped).
    public static func loadComponents() {
        _ = componentCount()
        var audioFile = AudioComponentDescription(
            componentType: audioFileComponentType,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        _ = AudioComponentFindNext(nil, &audioFile)
    }

    /// `'afil'`, the component type of audio file readers and writers.
    static let audioFileComponentType: OSType = 0x6166_696C

    /// How many audio components the system lists. Fetches the list on first use.
    public static func componentCount() -> UInt32 {
        var any = AudioComponentDescription()
        return AudioComponentCount(&any)
    }
}
#endif
