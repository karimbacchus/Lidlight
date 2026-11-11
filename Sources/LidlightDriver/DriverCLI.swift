import Foundation
import LidlightKit

/// A parsed `lidlightctl` hardware command.
package enum DriverCommand: Equatable {
    case help
    case status(json: Bool)
    case on
    case off
    case level(nits: Double)
    case tables
    case restore(powerOn: Bool)
    case fade(FactorTarget, seconds: Double?)
    case measureRamp(durations: [Double])
    case guardian(parentPID: Int32)
}

package struct CLIUsageError: Error, Equatable, CustomStringConvertible {
    package var description: String
}

/// `lidlightctl` commands other than `agent-event` and `audio-test`
/// (status, on, off, level, fade, restore, measure-ramp, guard, …).
public enum DriverCLI {
    package static let defaultMeasureDurations = [0.3, 1, 2, 4]

    package static let helpText = """
        usage: lidlightctl <command>

          status [--json]            logo power, live pipeline state, tables, safety marker
          on | off                   switch the logo on or off (LEBacklightMode; costs NVRAM writes)
          level <nits>               flat brightness table, 0...1000 nits (applies at the next
                                     display-brightness update; `restore` undoes it)
          tables                     print the three brightness tables
          restore [--on]             Apple's tables, no fade override, factor lit (--on: power on too)
          fade <dark|lit> [seconds]  ramp the animation factor (optionally set the fade duration)
          measure-ramp [seconds…]    sample the factor ramp at ~100 Hz, print CSV and the fitted a
                                     (default durations: 0.3 1 2 4)
          guard --parent-pid <pid>   crash guardian started by the app (restores on parent exit)
          help                       this text
        """

    // MARK: Parsing

    package static func parse(_ arguments: [String]) throws -> DriverCommand {
        guard let name = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())
        switch name {
        case "help", "-h", "--help":
            return .help
        case "status":
            try requireOnly(rest, allowed: ["--json"], command: name)
            return .status(json: rest.contains("--json"))
        case "on":
            try requireOnly(rest, allowed: [], command: name)
            return .on
        case "off":
            try requireOnly(rest, allowed: [], command: name)
            return .off
        case "tables":
            try requireOnly(rest, allowed: [], command: name)
            return .tables
        case "restore":
            try requireOnly(rest, allowed: ["--on"], command: name)
            return .restore(powerOn: rest.contains("--on"))
        case "level":
            guard rest.count == 1, let nits = Double(rest[0]), nits.isFinite,
                  nits >= 0, nits <= LogoLimits.maxNits else {
                throw CLIUsageError(description: "usage: lidlightctl level <nits 0...\(Int(LogoLimits.maxNits))>")
            }
            return .level(nits: nits)
        case "fade":
            guard let word = rest.first, word == "dark" || word == "lit", rest.count <= 2 else {
                throw CLIUsageError(description: "usage: lidlightctl fade <dark|lit> [seconds]")
            }
            var seconds: Double?
            if rest.count == 2 {
                guard let value = Double(rest[1]), value.isFinite, value > 0, value <= 60 else {
                    throw CLIUsageError(description: "fade seconds must be a number in (0, 60]")
                }
                seconds = value
            }
            return .fade(word == "dark" ? .dark : .lit, seconds: seconds)
        case "measure-ramp":
            let durations = try rest.map { argument -> Double in
                guard let value = Double(argument), value.isFinite, value > 0, value <= 10 else {
                    throw CLIUsageError(description: "measure-ramp durations must be numbers in (0, 10]")
                }
                return value
            }
            return .measureRamp(durations: durations.isEmpty ? defaultMeasureDurations : durations)
        case "guard":
            guard rest.count == 2, rest[0] == "--parent-pid", let pid = Int32(rest[1]), pid > 0 else {
                throw CLIUsageError(description: "usage: lidlightctl guard --parent-pid <pid>")
            }
            return .guardian(parentPID: pid)
        default:
            throw CLIUsageError(description: "unknown command '\(name)' (try `lidlightctl help`)")
        }
    }

    private static func requireOnly(_ arguments: [String], allowed: Set<String>, command: String) throws {
        if let extra = arguments.first(where: { !allowed.contains($0) }) {
            throw CLIUsageError(description: "unexpected argument '\(extra)' for `\(command)`")
        }
    }

    // MARK: Running

    public static func run(_ arguments: [String]) -> Int32 {
        let command: DriverCommand
        do {
            command = try parse(arguments)
        } catch {
            fail("\(error)")
            return 2
        }
        if command == .help {
            print(helpText)
            return 0
        }
        guard let driver = CoreBrightnessLogoDriver() else {
            fail(String(describing: LogoDriverError.unsupported))
            return 1
        }
        do {
            return try execute(command, driver: driver)
        } catch {
            fail("\(error)")
            return 1
        }
    }

    private static func execute(_ command: DriverCommand, driver: CoreBrightnessLogoDriver) throws -> Int32 {
        switch command {
        case .help:
            return 0
        case .status(let json):
            return try status(driver: driver, json: json)
        case .on:
            try driver.setPower(.on)
            print("logo on")
        case .off:
            try driver.setPower(.off)
            print("logo off")
        case .level(let nits):
            try driver.writeTables(LogoTables(
                mapping: .flat(nits), minRestriction: .flat(0), maxRestriction: .flat(LogoLimits.maxNits)))
            print("tables set to a flat \(format(nits)) nits; corebrightnessd applies them at its next "
                + "display-brightness update. `lidlightctl restore` puts Apple's tables back.")
        case .tables:
            printTables(try require(driver.readTables(), "cannot read the brightness tables"))
        case .restore(let powerOn):
            driver.setAnimationAllowed(MacHardware.animationPossible())
            try driver.restoreSystemDefaults(powerOn: powerOn)
            print("restored Apple's tables, no fade override, factor lit" + (powerOn ? ", logo on" : ""))
        case .fade(let target, let seconds):
            try requireAnimationPossible()
            if let seconds { try driver.setFadeDuration(seconds) }
            try driver.setFactorTarget(target)
            print("factor ramping \(target == .dark ? "dark" : "lit"); `lidlightctl restore` ends the override")
        case .measureRamp(let durations):
            try measureRamp(driver: driver, durations: durations)
        case .guardian(let parentPID):
            return Guardian.run(parentPID: parentPID, driver: driver)
        }
        return 0
    }

    // MARK: Commands

    private struct StatusReport: Codable {
        var power: Int
        var state: LogoState
        var tablesAreAppleDefaults: Bool
        var dirtyMarkerPresent: Bool
        var dirtyMarkerTables: Bool
        var dirtyMarkerFactor: Bool
    }

    private static func status(driver: CoreBrightnessLogoDriver, json: Bool) throws -> Int32 {
        let power = try require(driver.readPower(), "cannot read LEBacklightMode")
        let state = try require(driver.readState(), "cannot read LEPWMState")
        let tables = try require(driver.readTables(), "cannot read the brightness tables")
        let marker = DirtyMarker.read(from: AppPaths.dirtyMarkerURL)
        let report = StatusReport(
            power: power.rawValue, state: state, tablesAreAppleDefaults: isAppleDefault(tables),
            dirtyMarkerPresent: marker != nil, dirtyMarkerTables: marker?.tablesModified ?? false,
            dirtyMarkerFactor: marker?.factorModified ?? false)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            return 0
        }
        print("power        \(power == .on ? "on" : "off") (LEBacklightMode \(power.rawValue))")
        print("final        \(format(state.finalNits)) nits  (applied \(format(state.appliedNits)), factor \(format(state.factor, digits: 3)), multiplier \(format(state.multiplier, digits: 3)))")
        print("display      \(format(state.displayNits)) nits, \(format(state.lux)) lux")
        print("restriction  \(format(state.minRestrictionNits)) ... \(format(state.maxRestrictionNits)) nits (pre-restriction \(format(state.preRestrictionNits)))")
        print("tables       \(report.tablesAreAppleDefaults ? "Apple defaults" : "modified")")
        if let marker {
            let what = [marker.tablesModified ? "tables" : nil, marker.factorModified ? "factor" : nil].compactMap { $0 }
            print("safety       marker present (pid \(marker.pid), \(what.joined(separator: ", ")))")
        } else {
            print("safety       no marker")
        }
        return 0
    }

    private static func measureRamp(driver: CoreBrightnessLogoDriver, durations: [Double]) throws {
        try requireAnimationPossible()
        driver.setAnimationAllowed(true)
        var failure: Error?
        var recordings: [RampRecording] = []
        do {
            recordings = try RampMeasurement(driver: driver).run(durations: durations)
        } catch {
            failure = error
        }
        do { try driver.restoreSystemDefaults(powerOn: false) } catch { failure = failure ?? error }
        if let failure { throw failure }

        print("duration,direction,t,factor")
        for recording in recordings {
            for sample in recording.samples {
                print("\(recording.duration),\(recording.target == .dark ? "dark" : "lit"),\(format(sample.t, digits: 4)),\(format(sample.factor, digits: 4))")
            }
        }
        for recording in recordings {
            let settle = recording.settleTime().map { format($0, digits: 3) } ?? "never"
            let a = RampFit.fitA([recording]).map { format($0, digits: 2) } ?? "n/a"
            print("# duration \(recording.duration) \(recording.target == .dark ? "dark" : "lit"): a=\(a), within 1% of target after \(settle) s")
        }
        let pooled = RampFit.fitA(recordings).map { format($0, digits: 2) } ?? "n/a"
        print("# pooled a = \(pooled)  (remaining(u) = (g(a u) - g(a)) / (1 - g(a)), g(x) = (1 + x) e^-x)")
    }

    // MARK: Helpers

    private static func requireAnimationPossible() throws {
        guard MacHardware.animationPossible() else {
            throw LogoDriverError.notAllowed("the built-in display is asleep or the lid is closed")
        }
    }

    private static func isAppleDefault(_ tables: LogoTables) -> Bool {
        let defaults = LogoTables.appleDefaults
        return tables.mapping.isClose(to: defaults.mapping)
            && tables.minRestriction.isClose(to: defaults.minRestriction)
            && tables.maxRestriction.isClose(to: defaults.maxRestriction)
    }

    private static func printTables(_ tables: LogoTables) {
        for (key, table) in tables.keyedTables {
            print(key)
            for point in table.points {
                let x = point.x >= NitsTable.infinity ? "inf" : format(point.x)
                print("  \(x) -> \(format(point.y))")
            }
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw LogoDriverError.notAllowed(message) }
        return value
    }

    private static func format(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("lidlightctl: \(message)\n".utf8))
    }
}
