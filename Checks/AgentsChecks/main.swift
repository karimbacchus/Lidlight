// Agents module checks. Run: swift run AgentsChecks
// Everything uses temp directories; the real Claude Code settings are never touched.

import Foundation
import notify
import TestKit
import LidlightAgents
import LidlightKit

signal(SIGPIPE, SIG_IGN)  // the oversized-input check abandons a pipe mid-write
let t = TestRun("Agents")

// MARK: Helpers

func tempDir(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lidlight-agents-checks-\(name)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
func runHook(_ json: String, spool: URL) -> Int32 {
    let pipe = Pipe()
    let writer = pipe.fileHandleForWriting
    // Written off-thread: inputs larger than the pipe buffer would otherwise block before `run` reads.
    DispatchQueue.global().async {
        try? writer.write(contentsOf: Data(json.utf8))
        try? writer.close()
    }
    return AgentHookCommand.run(arguments: ["--spool", spool.path], stdin: pipe.fileHandleForReading)
}

func payload(_ event: String, session: String = "sess-1", extra: String = "") -> String {
    """
    {"session_id":"\(session)","transcript_path":"/Users/x/.claude/projects/p/\(session).jsonl",\
    "cwd":"/Users/x/proj","permission_mode":"default","hook_event_name":"\(event)"\(extra)}
    """
}

func readRecord(_ spool: URL, _ stem: String) -> AgentSessionRecord? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = try? Data(contentsOf: spool.appendingPathComponent(stem + ".json")) else { return nil }
    return try? decoder.decode(AgentSessionRecord.self, from: data)
}

func writeRecord(_ spool: URL, id: String, _ activity: AgentActivity, at date: Date) {
    let record = AgentSessionRecord(sessionID: id, activity: activity, lastEvent: "x", updatedAt: date, cwd: nil)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try! encoder.encode(record).write(to: spool.appendingPathComponent(id + ".json"))
}

// MARK: Hook command

t.test("event to activity mapping") {
    let spool = tempDir("map")
    let expected: [(String, AgentActivity)] = [
        ("SessionStart", .waiting), ("UserPromptSubmit", .working), ("PreToolUse", .working),
        ("PostToolUse", .working), ("SubagentStop", .working), ("Notification", .needsYou),
        ("PermissionRequest", .needsYou), ("Stop", .waiting),
    ]
    for (event, activity) in expected {
        t.expectEqual(runHook(payload(event), spool: spool), 0)
        let record = readRecord(spool, "sess-1")
        t.expectEqual(record?.activity, activity, event)
        t.expectEqual(record?.lastEvent, event)
        t.expectEqual(record?.cwd, "/Users/x/proj")
        t.expectEqual(record?.sessionID, "sess-1")
    }
}

t.test("SessionEnd deletes the record; auth_success and unknown events are ignored") {
    let spool = tempDir("end")
    runHook(payload("Stop"), spool: spool)
    runHook(payload("Notification", extra: ",\"notification_type\":\"auth_success\""), spool: spool)
    t.expectEqual(readRecord(spool, "sess-1")?.lastEvent, "Stop")
    runHook(payload("FileChanged"), spool: spool)
    t.expectEqual(readRecord(spool, "sess-1")?.lastEvent, "Stop")
    runHook(payload("SessionEnd", extra: ",\"reason\":\"other\""), spool: spool)
    t.expect(readRecord(spool, "sess-1") == nil)
    t.expectEqual(runHook(payload("SessionEnd", session: "never-existed"), spool: spool), 0)
}

t.test("posts the Darwin notification") {
    let spool = tempDir("notify")
    var token: Int32 = 0
    t.expectEqual(notify_register_check(AppInfo.agentsChangedNotification, &token), UInt32(NOTIFY_STATUS_OK))
    var changed: Int32 = 0
    notify_check(token, &changed)  // first check always reports true
    notify_check(token, &changed)
    t.expectEqual(changed, 0)
    runHook(payload("Stop"), spool: spool)
    // notifyd updates the shared check state asynchronously.
    for _ in 0..<100 where changed == 0 {
        notify_check(token, &changed)
        if changed == 0 { usleep(10_000) }
    }
    t.expectEqual(changed, 1)
    notify_cancel(token)
}

t.test("garbage, empty and oversized stdin exit 0 without writing") {
    let spool = tempDir("garbage")
    for input in ["", "not json", "[1,2,3]", "{}", "{\"hook_event_name\":\"Stop\"}", "{\"session_id\":7}",
                  String(repeating: "x", count: 2_000_000)] {
        t.expectEqual(runHook(input, spool: spool), 0)
    }
    t.expectEqual((try? FileManager.default.contentsOfDirectory(atPath: spool.path))?.count, 0)
}

t.test("creates a missing spool directory and leaves no temp files") {
    let spool = tempDir("missing").appendingPathComponent("nested/agents")
    runHook(payload("Stop"), spool: spool)
    t.expectEqual((try? FileManager.default.contentsOfDirectory(atPath: spool.path)) ?? [], ["sess-1.json"])
}

t.test("session id sanitization") {
    let spool = tempDir("sanitize")
    let hostile = ["../../etc/passwd", "a/b", ".hidden", "sp ace", String(repeating: "a", count: 200), "ünï"]
    for id in hostile {
        runHook(payload("Stop", session: id.replacingOccurrences(of: "\"", with: "")), spool: spool)
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: spool.path)) ?? []
    t.expectEqual(names.count, hostile.count)
    for name in names {
        t.expect(name.range(of: "^[A-Za-z0-9._-]+\\.json$", options: .regularExpression) != nil, name)
        t.expect(!name.hasPrefix("."), name)
    }
    runHook(payload("Stop", session: "7d3c1e9a-1f2b-4c55-9a10-0123456789ab"), spool: spool)
    t.expect(readRecord(spool, "7d3c1e9a-1f2b-4c55-9a10-0123456789ab") != nil)
    runHook(payload("Stop", session: "a/b"), spool: spool)
    runHook(payload("SessionEnd", session: "a/b"), spool: spool)
    t.expectEqual(((try? FileManager.default.contentsOfDirectory(atPath: spool.path)) ?? []).count, hostile.count)
}

t.test("run timing") {
    let spool = tempDir("timing")
    var samples: [Double] = []
    for i in 0..<50 {
        let start = DispatchTime.now().uptimeNanoseconds
        runHook(payload(i % 2 == 0 ? "PreToolUse" : "PostToolUse"), spool: spool)
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    samples.sort()
    print(String(format: "    run(): p50 %.2f ms, p95 %.2f ms, max %.2f ms (debug build)",
                 samples[25], samples[47], samples[49]))
    t.expect(samples[25] < 50, "p50 should be under 50 ms")
}

// MARK: Monitor

t.test("aggregation priority, staleness and expiry") {
    let spool = tempDir("monitor")
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let monitor = AgentMonitor(spoolDirectory: spool, now: { clock })
    var published: [AgentSnapshot] = []
    monitor.start { published.append($0) }
    defer { monitor.stop() }

    t.expectEqual(published.count, 1)
    t.expectEqual(monitor.snapshot.activity, .none)

    writeRecord(spool, id: "a", .waiting, at: clock)
    monitor.refresh()
    t.expectEqual(monitor.snapshot, AgentSnapshot(activity: .waiting, sessions: 1, working: 0, needingYou: 0, updatedAt: clock))

    writeRecord(spool, id: "b", .working, at: clock)
    monitor.refresh()
    t.expectEqual(monitor.snapshot.activity, .working)
    t.expectEqual(monitor.snapshot.sessions, 2)
    t.expectEqual(monitor.snapshot.working, 1)

    writeRecord(spool, id: "c", .needsYou, at: clock)
    monitor.refresh()
    t.expectEqual(monitor.snapshot.activity, .needsYou)
    t.expectEqual(monitor.snapshot.needingYou, 1)

    let count = published.count
    monitor.refresh()
    t.expectEqual(published.count, count, "no republish without change")

    try? FileManager.default.removeItem(at: spool.appendingPathComponent("c.json"))
    clock.addTimeInterval(9 * 60)
    monitor.refresh()
    t.expectEqual(monitor.snapshot.activity, .working)
    clock.addTimeInterval(2 * 60)  // b is now 11 min old
    monitor.refresh()
    t.expectEqual(monitor.snapshot.activity, .waiting, "stale working counts as waiting")
    t.expectEqual(monitor.snapshot.working, 0)
    t.expectEqual(monitor.snapshot.sessions, 2)

    clock.addTimeInterval(12 * 3600)
    monitor.refresh()
    t.expectEqual(monitor.snapshot.activity, .none)
    t.expectEqual(monitor.snapshot.sessions, 0)
    t.expectEqual(((try? FileManager.default.contentsOfDirectory(atPath: spool.path)) ?? []).count, 0, "expired files deleted")
    t.expectEqual(published.last?.activity, AgentActivity.none)
}

t.test("monitor ignores corrupt files and reacts to the Darwin notification") {
    let spool = tempDir("monitor-notify")
    try! Data("{broken".utf8).write(to: spool.appendingPathComponent("bad.json"))
    let monitor = AgentMonitor(spoolDirectory: spool)
    var published: [AgentSnapshot] = []
    monitor.start { published.append($0) }
    defer { monitor.stop() }
    t.expectEqual(monitor.snapshot.sessions, 0)
    runHook(payload("UserPromptSubmit"), spool: spool)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    t.expectEqual(published.last?.activity, AgentActivity.working)
    monitor.stop()
    runHook(payload("Notification"), spool: spool)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    t.expectEqual(published.last?.activity, AgentActivity.working, "stop() cancels observation")
}

// MARK: Installer

func readJSON(_ url: URL) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
}

func jsonEqual(_ a: Any, _ b: Any) -> Bool { (a as AnyObject).isEqual(b) }

let helper = "/Applications/Lidlight.app/Contents/Helpers/lidlightctl"
let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStop",
              "Notification", "PermissionRequest", "Stop", "SessionEnd"]

t.test("connect into a missing file and folder, then disconnect") {
    let url = tempDir("inst-missing").appendingPathComponent("new/settings.json")
    let installer = ClaudeHooksInstaller(settingsURL: url)
    t.expectEqual(installer.status(), .notInstalled)
    try installer.connect(helperPath: helper)
    t.expectEqual(installer.status(), .installed)
    let hooks = readJSON(url)?["hooks"] as? [String: Any] ?? [:]
    t.expectEqual(Set(hooks.keys), Set(events))
    let prompt = (hooks["UserPromptSubmit"] as? [[String: Any]])?.first
    t.expect(prompt?["matcher"] == nil, "UserPromptSubmit takes no matcher")
    let pre = (hooks["PreToolUse"] as? [[String: Any]])?.first
    t.expectEqual(pre?["matcher"] as? String, "*")
    let handler = (pre?["hooks"] as? [[String: Any]])?.first
    t.expectEqual(handler?["command"] as? String, "'\(helper)' agent-event")
    t.expectEqual(handler?["timeout"] as? Int, 5)
    t.expectEqual(handler?["type"] as? String, "command")
    let raw = try String(contentsOf: url)
    t.expect(!raw.contains("\\/"), "slashes not escaped")
    t.expect(!FileManager.default.fileExists(atPath: url.path + ".lidlight-backup"), "no backup for a new file")
    try installer.disconnect()
    t.expectEqual(installer.status(), .notInstalled)
    t.expect(readJSON(url)?["hooks"] == nil, "empty hooks object removed")
}

t.test("empty file") {
    let url = tempDir("inst-empty").appendingPathComponent("settings.json")
    try Data().write(to: url)
    let installer = ClaudeHooksInstaller(settingsURL: url)
    try installer.connect(helperPath: helper)
    t.expectEqual(installer.status(), .installed)
}

t.test("preserves unrelated settings and user hooks; idempotent; clean disconnect") {
    let url = tempDir("inst-merge").appendingPathComponent("settings.json")
    let original = """
    {
      "model": "opus", "env": {"A": "1"}, "permissions": {"allow": ["Bash(ls:*)"]},
      "hooks": {
        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/guard.sh", "timeout": 10}]}],
        "Stop": [{"hooks": [{"type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff"}]}],
        "PostToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "'/old/Lidlight.app/lidlightctl' agent-event"},
                                                  {"type": "command", "command": "echo keep"}]}],
        "FileChanged": [{"matcher": ".envrc", "hooks": [{"type": "command", "command": "direnv reload"}]}]
      }
    }
    """
    try Data(original.utf8).write(to: url)
    let before = readJSON(url)!
    let installer = ClaudeHooksInstaller(settingsURL: url)
    try installer.connect(helperPath: helper)
    t.expectEqual(installer.status(), .installed)
    let backupText = try String(contentsOf: URL(fileURLWithPath: url.path + ".lidlight-backup"))
    t.expectEqual(backupText, original)

    let after = readJSON(url)!
    t.expect(jsonEqual(after["model"]!, before["model"]!) && jsonEqual(after["env"]!, before["env"]!)
             && jsonEqual(after["permissions"]!, before["permissions"]!))
    let hooks = after["hooks"] as! [String: Any]
    t.expect(jsonEqual(hooks["FileChanged"]!, (before["hooks"] as! [String: Any])["FileChanged"]!))
    let pre = hooks["PreToolUse"] as! [[String: Any]]
    t.expectEqual(pre.count, 2)
    t.expectEqual(pre.first?["matcher"] as? String, "Bash")
    let post = hooks["PostToolUse"] as! [[String: Any]]
    let postCommands = post.flatMap { ($0["hooks"] as! [[String: Any]]).map { $0["command"] as! String } }
    t.expectEqual(postCommands, ["echo keep", "'\(helper)' agent-event"], "old lidlight entry replaced, user hook kept")

    let snapshot = try Data(contentsOf: url)
    try installer.connect(helperPath: helper)
    let after2 = try Data(contentsOf: url)
    t.expectEqual(after2, snapshot, "idempotent")

    try installer.disconnect()
    t.expectEqual(installer.status(), .notInstalled)
    let restored = readJSON(url)!
    var expected = before
    var expectedHooks = expected["hooks"] as! [String: Any]
    expectedHooks["PostToolUse"] = [["matcher": "*", "hooks": [["type": "command", "command": "echo keep"]]]]
    expected["hooks"] = expectedHooks
    t.expect(jsonEqual(restored, expected), "only our entries removed")
}

t.test("path change needs update; connect fixes it; quoting") {
    let url = tempDir("inst-path").appendingPathComponent("settings.json")
    let installer = ClaudeHooksInstaller(settingsURL: url)
    try installer.connect(helperPath: "/old/lidlightctl")
    let fresh = ClaudeHooksInstaller(settingsURL: url)
    t.expectEqual(fresh.status(), .installed, "no expected path: any consistent path is installed")
    fresh.expectedHelperPath = "/new place/it's/lidlightctl"
    t.expectEqual(fresh.status(), .needsUpdate)
    try fresh.connect(helperPath: "/new place/it's/lidlightctl")
    t.expectEqual(fresh.status(), .installed)
    let raw = try String(contentsOf: url)
    t.expect(raw.contains("'/new place/it'\\\\''s/lidlightctl' agent-event"), "single quotes escaped")
    t.expect(!raw.contains("/old/"), "old entries replaced")
}

t.test("partial installation reports needsUpdate") {
    let url = tempDir("inst-partial").appendingPathComponent("settings.json")
    let installer = ClaudeHooksInstaller(settingsURL: url)
    try installer.connect(helperPath: helper)
    var root = readJSON(url)!
    var hooks = root["hooks"] as! [String: Any]
    hooks["SessionEnd"] = nil
    root["hooks"] = hooks
    try JSONSerialization.data(withJSONObject: root).write(to: url)
    t.expectEqual(installer.status(), .needsUpdate)
    try installer.connect(helperPath: helper)
    t.expectEqual(installer.status(), .installed)
}

t.test("invalid JSON is an error and the file is untouched") {
    let url = tempDir("inst-invalid").appendingPathComponent("settings.json")
    let junk = Data("{ \"model\": \"opus\", // oops\n".utf8)
    try junk.write(to: url)
    let installer = ClaudeHooksInstaller(settingsURL: url)
    if case .error = installer.status() {} else { t.fail("expected .error, got \(installer.status())") }
    do { try installer.connect(helperPath: helper); t.fail("connect should throw") } catch {}
    do { try installer.disconnect(); t.fail("disconnect should throw") } catch {}
    let afterAttempts = try Data(contentsOf: url)
    t.expectEqual(afterAttempts, junk)
    t.expect(!FileManager.default.fileExists(atPath: url.path + ".lidlight-backup"))
}

t.finish()
