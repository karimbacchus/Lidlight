import Foundation

// MARK: - Power

/// Power state of the logo light, stored by corebrightnessd under `LEBacklightMode`.
///
/// Only `.off` (0) and `.on` (2, Apple's default "automatic") are valid. Value 1 exists in
/// corebrightnessd but does not behave as a usable state — never write it.
///
/// Every change of this value makes corebrightnessd write two NVRAM variables
/// (`bklb-backlight-dc`, `bklb-backlight-frequency`). Only change it for explicit user actions
/// (the on/off switch), never for effects or blinking.
public enum LogoPower: Int, Sendable, Codable, CaseIterable {
    case off = 0
    case on = 2
}

// MARK: - Animation factor

/// Target for the logo's animation "factor" channel (see docs/HARDWARE.md, "Factor channel").
/// `.dark` ramps the factor toward 0, `.lit` ramps it toward 1, over the current fade duration.
/// The ramp runs inside corebrightnessd at 60 Hz; reversing mid-ramp starts a new ramp from
/// the current factor.
public enum FactorTarget: Sendable, Equatable {
    case lit
    case dark
}

// MARK: - Live state

/// Live state of the logo pipeline, decoded from corebrightnessd's `LEPWMState` dictionary.
///
/// Pipeline: displayNits → mapping table → clamp(min, max restriction by lux) → rate limiter
/// (appliedNits) × multiplier × factor → finalNits (0 when LEBacklightMode is off).
public struct LogoState: Sendable, Equatable, Codable {
    /// Nits the LED is driven to right now (`FinalNits`).
    public var finalNits: Double
    /// Nits after restrictions and rate limiting, before the factor (`AppliedNits`).
    public var appliedNits: Double
    /// Animation factor 0...1 (`Factor`).
    public var factor: Double
    /// Built-in display nits the logo mapping last saw (`DisplayNits`; can be stale).
    public var displayNits: Double
    /// Ambient light the logo module last saw, in lux (`Lux`; coarse, updates rarely).
    public var lux: Double
    /// Current lower clamp from the lux → min table (`MinNitsRestriction`).
    public var minRestrictionNits: Double
    /// Current upper clamp from the lux → max table (`MaxNitsRestriction`).
    public var maxRestrictionNits: Double
    /// Mapping-table output before restrictions (`PWMNitsPreRestriction`).
    public var preRestrictionNits: Double
    /// Charger / enclosure multiplier (`NitsMultiplier`).
    public var multiplier: Double

    public init(
        finalNits: Double = 0,
        appliedNits: Double = 0,
        factor: Double = 1,
        displayNits: Double = 0,
        lux: Double = 0,
        minRestrictionNits: Double = 0,
        maxRestrictionNits: Double = LogoLimits.maxNits,
        preRestrictionNits: Double = 0,
        multiplier: Double = 1
    ) {
        self.finalNits = finalNits
        self.appliedNits = appliedNits
        self.factor = factor
        self.displayNits = displayNits
        self.lux = lux
        self.minRestrictionNits = minRestrictionNits
        self.maxRestrictionNits = maxRestrictionNits
        self.preRestrictionNits = preRestrictionNits
        self.multiplier = multiplier
    }
}

public enum LogoLimits {
    /// Highest logo output corebrightnessd uses (nits).
    public static let maxNits: Double = 1000
    /// Lowest non-zero level we offer on the brightness slider (nits).
    public static let minNits: Double = 3
}

// MARK: - Tables

/// Piecewise-linear table used by corebrightnessd for the logo (x → nits).
/// x is display nits for the mapping table and lux for the restriction tables.
/// Points must be sorted by strictly increasing x; the last point conventionally uses
/// `NitsTable.infinity` (FLT_MAX) as x.
public struct NitsTable: Sendable, Equatable, Codable {
    public struct Point: Sendable, Equatable, Codable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public var points: [Point]

    public init(points: [Point]) {
        self.points = points
    }

    public init(_ pairs: [(Double, Double)]) {
        self.points = pairs.map { Point(x: $0.0, y: $0.1) }
    }

    /// corebrightnessd's "and above" sentinel: FLT_MAX.
    public static let infinity: Double = Double(Float.greatestFiniteMagnitude)

    /// A table that yields `nits` for every input.
    public static func flat(_ nits: Double) -> NitsTable {
        NitsTable([(0, nits), (infinity, nits)])
    }

    /// Linear interpolation; clamps outside the table's range.
    public func value(at x: Double) -> Double {
        guard let first = points.first else { return 0 }
        if x <= first.x { return first.y }
        for (a, b) in zip(points, points.dropFirst()) where x <= b.x {
            let span = b.x - a.x
            if span <= 0 { return b.y }
            let t = (x - a.x) / span
            return a.y + (b.y - a.y) * t
        }
        return points.last!.y
    }

    /// True if x is strictly increasing, all values are finite and non-negative, and there are ≥ 2 points.
    public var isValid: Bool {
        guard points.count >= 2 else { return false }
        for p in points where !p.x.isFinite || !p.y.isFinite || p.x < 0 || p.y < 0 { return false }
        for (a, b) in zip(points, points.dropFirst()) where !(b.x > a.x) { return false }
        return true
    }

    /// Wire format corebrightnessd expects: an array of [x, y] number pairs.
    public var propertyListValue: [[Double]] {
        points.map { [$0.x, $0.y] }
    }

    /// Decodes the wire format (`NSArray` of `NSArray<NSNumber>` pairs).
    public init?(propertyListValue: Any) {
        guard let rows = propertyListValue as? [Any] else { return nil }
        var pts: [Point] = []
        for row in rows {
            guard let pair = row as? [Any], pair.count == 2,
                  let x = (pair[0] as? NSNumber)?.doubleValue,
                  let y = (pair[1] as? NSNumber)?.doubleValue else { return nil }
            pts.append(Point(x: x, y: y))
        }
        self.points = pts
    }
}

/// The three persisted tables that decide the logo's brightness.
public struct LogoTables: Sendable, Equatable, Codable {
    /// `LEPWMBrightnessNitsMapping`: display nits → logo nits.
    public var mapping: NitsTable
    /// `LEPWMLuxToMinNitsRestrictionMapping`: ambient lux → minimum logo nits.
    public var minRestriction: NitsTable
    /// `LEPWMLuxToMaxNitsRestrictionMapping`: ambient lux → maximum logo nits.
    public var maxRestriction: NitsTable

    public init(mapping: NitsTable, minRestriction: NitsTable, maxRestriction: NitsTable) {
        self.mapping = mapping
        self.minRestriction = minRestriction
        self.maxRestriction = maxRestriction
    }

    /// Apple's shipping values, read from corebrightnessd on a Mac17,12 running macOS 27.2.
    /// (Float values are stored exactly as corebrightnessd reports them.)
    public static let appleDefaults = LogoTables(
        mapping: NitsTable([
            (0, 0),
            (0.10000000149011612, 12.5),
            (16.840000152587891, 12.5),
            (34.119998931884766, 28.620000839233398),
            (50, 45.369998931884766),
            (69.110000610351562, 65.519996643066406),
            (140, 150),
            (300, 300),
            (600, 1000),
            (NitsTable.infinity, 1000),
        ]),
        minRestriction: NitsTable([
            (0, 12.5),
            (190, 150),
            (560, 300),
            (1350, 1000),
            (NitsTable.infinity, 1000),
        ]),
        maxRestriction: NitsTable([
            (0, 180),
            (190, 1000),
            (NitsTable.infinity, 1000),
        ])
    )
}

// MARK: - Property keys

/// Property keys used with CoreBrightness's `BrightnessSystemClient`. See docs/HARDWARE.md
/// before writing any of them.
public enum LogoKey {
    /// Int 0 (off) or 2 (on/automatic). Instant. Costs NVRAM writes per change.
    public static let backlightMode = "LEBacklightMode"
    /// Read-only dictionary with the live pipeline state.
    public static let state = "LEPWMState"
    /// Table: display nits → logo nits. Persisted; applied on the next display-brightness update.
    public static let mapping = "LEPWMBrightnessNitsMapping"
    /// Table: lux → min logo nits. Persisted; applied on the next ambient-light update.
    public static let minRestriction = "LEPWMLuxToMinNitsRestrictionMapping"
    /// Table: lux → max logo nits. Persisted; applied on the next ambient-light update.
    public static let maxRestriction = "LEPWMLuxToMaxNitsRestrictionMapping"
    /// Seconds (> 0) used for every factor ramp ("constant, everywhere"); 0 restores Apple's
    /// per-sequence curves. In-memory only; ignored by every other corebrightnessd module.
    public static let factorFadeDuration = "LEPWMFactorFadeDuration"
    /// Int. 1 = Blank (factor → 0), 2 = Unblank (factor → 1). Shared with the keyboard backlight
    /// container (it reacts as if the display blanked). Write only while the built-in display is
    /// awake and the lid is open, and always leave it at 2.
    public static let displayLogicalState = "DisplayLogicalState"

    /// FORBIDDEN. The display module acts on this key: writing it blanked the built-in display
    /// during research. Listed only so reviews can grep for it. Never write it.
    public static let forbiddenDisplayPowerStateEvent = "DisplayPowerStateEvent"
}

// MARK: - Errors

public enum LogoDriverError: Error, Sendable, CustomStringConvertible {
    case unsupported
    case writeFailed(key: String)
    case invalidTable(String)
    case notAllowed(String)

    public var description: String {
        switch self {
        case .unsupported: return "This Mac has no controllable logo light."
        case .writeFailed(let key): return "corebrightnessd rejected a write to \(key)."
        case .invalidTable(let why): return "Invalid brightness table: \(why)"
        case .notAllowed(let why): return "Not allowed: \(why)"
        }
    }
}

// MARK: - Driver protocol

/// Hardware abstraction for the lid logo.
///
/// Implementations (module LidlightDriver): `CoreBrightnessLogoDriver` (real hardware) and
/// `SimulatedLogoDriver` (for --simulate, previews and checks).
///
/// Thread-safe. Calls may block briefly on XPC (about 1 ms each).
public protocol LogoDriving: AnyObject, Sendable {
    /// True if this Mac has a controllable logo (LEBacklightMode and LEPWMState are readable).
    var isSupported: Bool { get }
    var isSimulated: Bool { get }

    func readState() -> LogoState?
    func readPower() -> LogoPower?

    /// User-initiated only (on/off switch, hotkey, quit flow). Each change costs NVRAM writes.
    /// Implementations rate-limit and skip writes that would not change anything.
    func setPower(_ power: LogoPower) throws

    func readTables() -> LogoTables?

    /// Persisted by corebrightnessd. The mapping applies at the next display-brightness update,
    /// restrictions at the next ambient-light update — not immediately.
    /// Implementations validate tables and skip writes of unchanged tables.
    func writeTables(_ tables: LogoTables) throws

    /// Gate for the animation channel. While false, `setFadeDuration`/`setFactorTarget` are
    /// no-ops and `releaseFactor` only clears the fade override. The engine sets this to false
    /// whenever the built-in display is asleep or the lid is closed.
    func setAnimationAllowed(_ allowed: Bool)

    /// Fade duration (seconds) used for subsequent factor ramps; nil restores Apple's curves.
    func setFadeDuration(_ seconds: Double?) throws

    /// Ramp the factor toward 0 (`.dark`) or 1 (`.lit`) over the current fade duration.
    func setFactorTarget(_ target: FactorTarget) throws

    /// Stop animating: factor → lit (only while animation is allowed) and fade duration → default.
    func releaseFactor() throws

    /// Put Apple's tables back, clear all overrides, and power on if requested.
    func restoreSystemDefaults(powerOn: Bool) throws
}

/// Something that can tell the UI how bright the logo is right now (preview window, readout).
public protocol LogoPreviewSource: AnyObject {
    /// Approximate current logo output as a fraction of `LogoLimits.maxNits` (0...1).
    func previewLevel() -> Double
}

/// Reports whether the built-in keyboard backlight is lit, so effects can avoid visible
/// side effects on it: every `DisplayLogicalState` dark phase switches the keyboard backlight off.
public protocol KeyboardBacklightProbing: AnyObject, Sendable {
    /// True when the built-in keyboard backlight would be on (user active, room dark enough) —
    /// independent of Lidlight's own dark phases, which zero the keyboard's live brightness.
    func isBuiltInKeyboardLit() -> Bool
}
