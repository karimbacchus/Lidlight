// lidlightctl — helper CLI bundled at Lidlight.app/Contents/Helpers/lidlightctl.
//
//   lidlightctl agent-event            Claude Code hook entry point (reads hook JSON on stdin)
//   lidlightctl audio-test [seconds]   capture system audio, print beats
//   lidlightctl <anything else>        hardware commands, see `lidlightctl help` (DriverCLI)

import Foundation
import LidlightKit
import LidlightDriver
import LidlightAgents
import LidlightAudio

let arguments = Array(CommandLine.arguments.dropFirst())
let code: Int32

switch arguments.first {
case "agent-event":
    code = AgentHookCommand.run(arguments: Array(arguments.dropFirst()), stdin: .standardInput)
case "audio-test":
    code = AudioCLI.run(Array(arguments.dropFirst()))
default:
    code = DriverCLI.run(arguments)
}

exit(code)
