import Darwin
import Foundation
import LidlightKit

/// `lidlightctl audio-test [seconds]`: capture system audio and print beats and a level meter.
public enum AudioCLI {
    /// Runs the command; returns the process exit code.
    public static func run(_ arguments: [String]) -> Int32 {
        var seconds = 15.0
        if let first = arguments.first {
            guard let value = Double(first), value > 0 else {
                printError("usage: lidlightctl audio-test [seconds]")
                return 2
            }
            seconds = value
        }

        let source = SystemAudioBeatSource()
        let begin = ProcessInfo.processInfo.systemUptime
        var lastMeter = 0.0
        var beatCount = 0

        do {
            try source.start(
                onBeat: { beat in
                    beatCount += 1
                    let t = beat.uptime - begin
                    let strong = beat.isStrong ? " strong" : ""
                    print(String(format: "t=%.2fs strength=%.2f%@", t, beat.strength, strong))
                },
                onLevel: { level in
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now - lastMeter >= 0.25 else { return }
                    lastMeter = now
                    let filled = Int((level * 20).rounded())
                    let bar = String(repeating: "#", count: filled) + String(repeating: ".", count: 20 - filled)
                    print(String(format: "level [%@] %.2f", bar, level))
                }
            )
        } catch AudioCaptureError.denied {
            printError("""
                Audio capture was denied. Allow it in System Settings > Privacy & Security >
                Screen & System Audio Recording (enable your terminal app, or Lidlight), then run again.
                """)
            SystemAudioBeatSource.openPrivacySettings()
            return 3
        } catch AudioCaptureError.unsupported {
            printError("System audio capture needs macOS 14.2 or later.")
            return 4
        } catch {
            printError("Could not start audio capture: \(error.localizedDescription)")
            return 1
        }

        print("Listening to system audio for \(Int(seconds)) s. Play some music. Ctrl-C to stop.")
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { CFRunLoopStop(CFRunLoopGetMain()) }
        interrupt.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { CFRunLoopStop(CFRunLoopGetMain()) }
        CFRunLoopRun()

        source.stop()
        print("Done: \(beatCount) beats in \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - begin)) s.")
        return 0
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
