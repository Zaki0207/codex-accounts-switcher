import Foundation

func check(_ condition: Bool) { precondition(condition) }

func expectError(_ action: () throws -> Void) {
    do { try action(); fatalError("Expected operation to fail") } catch {}
}

func fakeAuth(email: String, token: String) throws -> Data {
    let claims = try JSONSerialization.data(withJSONObject: ["email": email])
        .base64EncodedString().replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": [
        "id_token": "header.\(claims).signature", "account_id": "test-account",
        "access_token": token, "refresh_token": "fake-refresh"
    ]])
}

@main struct Regression {
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codex-accounts-tests-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let account = Account(id: UUID(), name: "Test", email: "test@example.invalid")

        // Service requests share IDs with responses, but must never be accepted as responses.
        for id: Any in [2, 99, "server-refresh"] {
            let message: [String: Any] = ["id": id, "method": "account/chatgptAuthTokens/refresh", "params": [:]]
            check(try RPCMessage.response(message, id: 2) == nil)
            var rejection: [String: Any]?
            expectError { _ = try RPCMessage.handleRequest(message) { rejection = $0 } }
            check(rejection?["error"] != nil)
            check(String(describing: rejection!["id"]!) == String(describing: id))
        }
        expectError { _ = try RPCMessage.response(["id": 2], id: 2) }
        expectError { _ = try RPCMessage.response(["id": 2, "error": NSNull()], id: 2) }
        let response = try RPCMessage.response(["id": 2, "result": ["ok": true]], id: 2)
        check(response?["ok"] as? Bool == true)
        check(AppServerClient.decodedRateLimits([:], email: account.email, plan: nil).snapshot == nil)
        print("PASS RPC request routing, error replies, and malformed quota rejection")

        let limits: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 25]]]
        check(AppServerClient.decodedRateLimits(limits, email: account.email, plan: nil).snapshot?.resetCredits == nil)
        for count in [0, 3] {
            var sample = limits
            sample["rateLimitResetCredits"] = ["availableCount": count, "credits": []] as [String: Any]
            check(AppServerClient.decodedRateLimits(sample, email: account.email, plan: nil).snapshot?.resetCredits?.availableCount == count)
        }
        try AppServerClient.validateFileStorage(["config": ["cli_auth_credentials_store": "file"]])
        for mode in ["keyring", "auto", "ephemeral", "unknown"] {
            expectError { try AppServerClient.validateFileStorage(["config": ["cli_auth_credentials_store": mode]]) }
        }
        expectError { try AppServerClient.validateFileStorage(["config": [:]]) }
        print("PASS quota states and credential storage validation")

        _ = try AuthSwitcher.prepareSlot(base: base, account: account)
        let slot = AuthSwitcher.slot(base: base, account: account)
        let old = try fakeAuth(email: account.email, token: "old")
        try old.write(to: slot)
        expectError {
            try AuthSwitcher.capture(base: base, account: account, allAccounts: [], reauthorize: true,
                authorize: { _ in throw ProbeError.timeout }, probe: { _ in fatalError("Must not probe") })
        }
        check(try Data(contentsOf: slot) == old)
        expectError {
            try AuthSwitcher.capture(base: base, account: account, allAccounts: [], reauthorize: true,
                authorize: { home in try fakeAuth(email: "wrong@example.invalid", token: "wrong").write(to: home.appendingPathComponent("auth.json")) },
                probe: { _ in ProbeResult(email: "wrong@example.invalid", snapshot: nil, rateError: nil) })
        }
        check(try Data(contentsOf: slot) == old)
        let cancelled = AuthorizationCancellation()
        cancelled.cancel()
        expectError {
            try AuthSwitcher.capture(base: base, account: account, allAccounts: [], reauthorize: true,
                cancellation: cancelled, authorize: { _ in fatalError("Cancelled login must not start") })
        }
        let duringValidation = AuthorizationCancellation()
        expectError {
            try AuthSwitcher.capture(base: base, account: account, allAccounts: [], reauthorize: true,
                cancellation: duringValidation,
                authorize: { home in try fakeAuth(email: account.email, token: "cancelled").write(to: home.appendingPathComponent("auth.json")) },
                probe: { _ in
                    duringValidation.cancel()
                    return ProbeResult(email: account.email, snapshot: nil, rateError: nil)
                })
        }
        check(try Data(contentsOf: slot) == old)
        let completed = AuthorizationCancellation()
        try completed.commit {}
        check(!completed.cancel())
        try completed.check()

        // Simulate a blocked child read without opening a browser or using credentials.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/cat")
        let childInput = Pipe(), childOutput = Pipe()
        child.standardInput = childInput
        child.standardOutput = childOutput
        try child.run()
        let runningCancellation = AuthorizationCancellation()
        runningCancellation.attach(child)
        let ended = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = childOutput.fileHandleForReading.readDataToEndOfFile()
            ended.signal()
        }
        runningCancellation.cancel()
        precondition(ended.wait(timeout: .now() + 2) == .success)
        child.waitUntilExit()
        runningCancellation.detach(child)
        try childInput.fileHandleForWriting.close()
        try childOutput.fileHandleForReading.close()
        check(!child.isRunning)
        print("PASS cancellation stops blocked child reads, preserves old auth, and fences final commit")

        let renewed = try fakeAuth(email: account.email, token: "renewed")
        try AuthSwitcher.capture(base: base, account: account, allAccounts: [], reauthorize: true,
            authorize: { home in try renewed.write(to: home.appendingPathComponent("auth.json")) },
            probe: { _ in ProbeResult(email: account.email, snapshot: nil, rateError: nil) })
        check(try Data(contentsOf: slot) == renewed)
        check(AuthSwitcher.needsActivation(base: base, account: account))
        try fakeAuth(email: account.email, token: "rotated").write(to: slot)
        check(AuthSwitcher.needsActivation(base: base, account: account))
        let permissions = try FileManager.default.attributesOfItem(atPath: slot.path)[.posixPermissions] as? NSNumber
        check(permissions?.intValue == 0o600)
        let vaultFiles = try FileManager.default.contentsOfDirectory(atPath: slot.deletingLastPathComponent().deletingLastPathComponent().path)
        check(!vaultFiles.contains(where: { $0.hasPrefix("login-") }))
        print("PASS cancelled/wrong-account authorization preserves old tokens; success stages activation")

        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let removed = DispatchSemaphore(value: 0), group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            try! AuthSwitcher.capture(base: base, account: account, allAccounts: [], reauthorize: true,
                authorize: { home in
                    entered.signal()
                    precondition(release.wait(timeout: .now() + 5) == .success)
                    try renewed.write(to: home.appendingPathComponent("auth.json"))
                }, probe: { _ in ProbeResult(email: account.email, snapshot: nil, rateError: nil) })
        }
        precondition(entered.wait(timeout: .now() + 5) == .success)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            try! AuthSwitcher.withVaultLock(base: base) {
                try AuthSwitcher.removeSlotLocked(base: base, account: account)
            }
            removed.signal()
        }
        check(removed.wait(timeout: .now() + 0.2) == .timedOut)
        release.signal()
        precondition(group.wait(timeout: .now() + 5) == .success)
        check(!FileManager.default.fileExists(atPath: slot.path))
        expectError { _ = try AuthSwitcher.prepareSlot(base: base, account: account) }
        expectError {
            try AuthSwitcher.capture(base: base, account: account, allAccounts: [], reauthorize: true,
                authorize: { _ in fatalError("Deleted account must not log in") },
                probe: { _ in fatalError("Deleted account must not probe") })
        }
        print("PASS deletion waits for authorization and rejects stale queued writes")

        let database = try AccountDatabase(base: base.appendingPathComponent("database"))
        try database.save(account)
        let model = DashboardModel(database: database, automaticRefresh: false)
        for operation in ["switch", "authorize", "delete", "open"] {
            model.exclusiveOperation = operation
            model.delete(account)
            model.openMain()
            model.switchAccount(account)
            model.saveDesktopAuth(account, reauthorize: true)
            model.refresh(account)
            check(!model.save(id: account.id, name: "Edited", email: account.email, url: "https://example.invalid"))
            check(model.exclusiveOperation == operation && model.busy.isEmpty)
            check(database.load().count == 1)
        }
        model.exclusiveOperation = nil
        model.busy.insert(account.id)
        model.delete(account)
        model.openMain()
        model.switchAccount(account)
        model.saveDesktopAuth(account)
        check(model.exclusiveOperation == nil && database.load().count == 1)
        print("PASS model blocks edit/delete/open/switch/authorization during active operations")

        // Exercise the bundled protocol only against an empty temporary home.
        if CommandLine.arguments.contains("--integration") {
            let home = base.appendingPathComponent("isolated-home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: home.appendingPathComponent("config.toml"))
            try AppServerClient.requireFileStorage(home: home)
            print("PASS bundled app-server config/read integration in isolated home")
        }
    }
}
