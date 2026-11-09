// Minimal test harness. XCTest and Swift Testing are unavailable with Command Line Tools only,
// so each module has a `<Module>Checks` executable built on this. Run: `swift run EngineChecks`.
//
//   let t = TestRun("Engine")
//   t.test("breathe alternates targets") {
//       t.expectEqual(targets, [.dark, .lit])
//   }
//   t.finish()   // prints a summary, exits 1 on any failure

import Foundation

public final class TestRun {
    private let suite: String
    private var currentTest = ""
    private var currentTestFailed = false
    private var passed = 0
    private var failed = 0
    private var failures: [String] = []

    public init(_ suite: String) {
        self.suite = suite
        print("▶︎ \(suite) checks")
    }

    /// Runs one named test. Thrown errors count as failures.
    public func test(_ name: String, _ body: () throws -> Void) {
        currentTest = name
        currentTestFailed = false
        do {
            try body()
        } catch {
            record("threw \(error)", file: #fileID, line: #line)
        }
        if currentTestFailed {
            failed += 1
            print("  ✗ \(name)")
        } else {
            passed += 1
            print("  ✓ \(name)")
        }
    }

    public func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "",
                       file: StaticString = #fileID, line: UInt = #line) {
        if !condition() { record("expectation failed \(message())", file: file, line: line) }
    }

    public func expectEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: @autoclosure () -> T,
                                          _ message: @autoclosure () -> String = "",
                                          file: StaticString = #fileID, line: UInt = #line) {
        let a = actual(), e = expected()
        if a != e { record("expected \(e), got \(a) \(message())", file: file, line: line) }
    }

    public func expectClose(_ actual: Double, _ expected: Double, tolerance: Double,
                            _ message: @autoclosure () -> String = "",
                            file: StaticString = #fileID, line: UInt = #line) {
        if !(abs(actual - expected) <= tolerance) {
            record("expected \(expected) ± \(tolerance), got \(actual) \(message())", file: file, line: line)
        }
    }

    public func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
        record(message, file: file, line: line)
    }

    /// Prints the summary and exits (0 if everything passed).
    public func finish() -> Never {
        print("\(suite): \(passed) passed, \(failed) failed")
        for f in failures { print("  - \(f)") }
        exit(failed == 0 ? 0 : 1)
    }

    private func record(_ message: String, file: StaticString, line: UInt) {
        currentTestFailed = true
        failures.append("[\(currentTest)] \(file):\(line): \(message)")
        print("    ↳ \(file):\(line): \(message)")
    }
}
