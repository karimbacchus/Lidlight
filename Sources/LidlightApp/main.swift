// Lidlight app composition root. Builds every service and hands them to the UI.
// Flags:
//   --simulate   use SimulatedLogoDriver (no hardware writes); also used when the Mac has no logo.

import AppKit
import LidlightKit
import LidlightDriver
import LidlightEngine
import LidlightSystem
import LidlightAgents
import LidlightAudio
import LidlightUI

let arguments = CommandLine.arguments
let forceSimulation = arguments.contains("--simulate")

try? AppPaths.ensureDirectories()

let hardwareDriver: CoreBrightnessLogoDriver? = forceSimulation ? nil : CoreBrightnessLogoDriver()
let driver: LogoDriving & LogoPreviewSource = hardwareDriver ?? SimulatedLogoDriver()

let helperURL = Bundle.main.bundleURL
    .appendingPathComponent("Contents/Helpers", isDirectory: true)
    .appendingPathComponent(AppInfo.helperExecutableName)

if !driver.isSimulated {
    // A previous run that crashed may have left corebrightnessd modified.
    SafetyRecovery.recoverIfNeeded(driver: driver)
    // Restores Apple's settings if this process dies without cleaning up.
    if FileManager.default.isExecutableFile(atPath: helperURL.path) {
        GuardianLauncher.launch(helperURL: helperURL)
    }
}

let engine = EffectEngine(driver: driver)
let system = SystemMonitor(keyboardProbe: driver.isSimulated ? nil : CoreBrightnessKeyboardProbe())
let agents = AgentMonitor()
// Knowing the bundled helper's path lets status() report "needs update" after the app moves.
let hooks = ClaudeHooksInstaller(expectedHelperPath: helperURL.path)
let beats = SystemAudioBeatSource()

let model = AppModel(
    driver: driver,
    preview: driver,
    engine: engine,
    system: system,
    agents: agents,
    hooks: hooks,
    beats: beats,
    helperURL: helperURL
)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController(model: model)
controller.start()
app.run()
