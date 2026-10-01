import AppKit
import Darwin
import Foundation

enum AuthSwitchError: LocalizedError {
    case missingAuth, invalidAuth, identityMismatch, unknownCurrentAccount, appStillRunning
    case isolatedAppRunning, io(String)

    var errorDescription: String? {
        switch self {
        case .missingAuth: return "这个账号还没有保存桌面登录授权"
        case .invalidAuth: return "桌面登录授权文件不完整"
        case .identityMismatch: return "授权文件与账号卡片的邮箱不一致"
        case .unknownCurrentAccount: return "当前桌面授权不属于已添加的账号；已停止切换"
        case .appStillRunning: return "Codex 未能完全退出；授权文件没有替换"
        case .isolatedAppRunning: return "检测到旧版独立 Codex 窗口，请先退出该窗口"
        case .io(let message): return message
        }
    }
}

enum AuthSwitcher {
    static let sharedAuth = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex/auth.json")

    private static func root(base: URL) -> URL {
        base.appendingPathComponent("desktop-switch", isDirectory: true)
    }

    static func slot(base: URL, account: Account) -> URL {
        root(base: base).appendingPathComponent(account.id.uuidString, isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    static func hasSlot(base: URL, account: Account) -> Bool {
        (try? read(slot(base: base, account: account), for: account)) != nil
    }

    static func activeAccount(accounts: [Account]) -> Account? {
        guard let data = try? Data(contentsOf: sharedAuth),
              let identity = try? identity(from: data) else { return nil }
        return accounts.first { $0.email.caseInsensitiveCompare(identity.email) == .orderedSame }
    }

    private struct Identity {
        let email: String
        let accountID: String
    }

    struct AccessCredential {
        let token: String
        let accountID: String
        let email: String
    }

    static func accessCredential(base: URL, account: Account) throws -> AccessCredential {
        try ensureNotDeleted(base: base, account: account)
        let active = activeAccount(accounts: [account])?.id == account.id
        let source = active ? sharedAuth : slot(base: base, account: account)
        let data = try read(source, for: account)
        let identity = try identity(from: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            throw AuthSwitchError.invalidAuth
        }
        return AccessCredential(token: access, accountID: identity.accountID, email: identity.email)
    }

    private static func identity(from data: Data) throws -> Identity {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["auth_mode"] as? String == "chatgpt",
              let tokens = object["tokens"] as? [String: Any],
              let accountID = tokens["account_id"] as? String, !accountID.isEmpty,
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty,
              let idToken = tokens["id_token"] as? String,
              idToken.split(separator: ".").count == 3 else { throw AuthSwitchError.invalidAuth }
        let part = String(idToken.split(separator: ".")[1])
        let padding = String(repeating: "=", count: (4 - part.count % 4) % 4)
        guard let claimsData = Data(base64Encoded: part.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding),
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              let email = claims["email"] as? String, !email.isEmpty else {
            throw AuthSwitchError.invalidAuth
        }
        return Identity(email: email, accountID: accountID)
    }

    private static func read(_ path: URL, for account: Account) throws -> Data {
        guard FileManager.default.isReadableFile(atPath: path.path) else { throw AuthSwitchError.missingAuth }
        let data = try Data(contentsOf: path)
        let actual = try identity(from: data)
        guard actual.email.caseInsensitiveCompare(account.email) == .orderedSame else {
            throw AuthSwitchError.identityMismatch
        }
        return data
    }

    static func prepareSlot(base: URL, account: Account) throws -> URL {
        try ensureNotDeleted(base: base, account: account)
        let directory = slot(base: base, account: account).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let config = directory.appendingPathComponent("config.toml")
        if !FileManager.default.fileExists(atPath: config.path) {
            try atomicWrite(Data("cli_auth_credentials_store = \"file\"\n".utf8), to: config)
        }
        guard try String(contentsOf: config, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                == "cli_auth_credentials_store = \"file\"" else {
            throw AuthSwitchError.io("桌面授权存储设置不符合预期")
        }
        return directory
    }

    static func withVaultLock<T>(base: URL, cancellation: AuthorizationCancellation? = nil,
                                 action: () throws -> T) throws -> T {
        let fd = try acquireLock(base: base, cancellation: cancellation)
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        return try action()
    }

    private static func acquireLock(base: URL, cancellation: AuthorizationCancellation?) throws -> Int32 {
        try cancellation?.check()
        let vault = root(base: base)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vault.path)
        let lockPath = vault.appendingPathComponent(".switch.lock")
        let fd = Darwin.open(lockPath.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError("无法锁定授权目录") }
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            do { try cancellation?.check() } catch { Darwin.close(fd); throw error }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            if errno != EWOULDBLOCK {
                let error = posixError("无法锁定授权目录")
                Darwin.close(fd)
                throw error
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        Darwin.close(fd)
        throw AuthSwitchError.io("授权目录正忙，请稍后再试")
    }

    static func capture(base: URL, account: Account, allAccounts: [Account],
                        reauthorize: Bool = false,
                        cancellation: AuthorizationCancellation = AuthorizationCancellation(),
                        authorize: ((URL) throws -> Void)? = nil,
                        probe: ((URL) throws -> ProbeResult)? = nil) throws {
        try withVaultLock(base: base, cancellation: cancellation) {
            try cancellation.check()
            _ = try prepareSlot(base: base, account: account)
            if !reauthorize, let active = activeAccount(accounts: allAccounts), active.id == account.id {
                let data = try read(sharedAuth, for: account)
                try cancellation.commit { try atomicWrite(data, to: slot(base: base, account: account)) }
                return
            }
            // Do not give a login attempt access to the last known good slot.
            let staging = root(base: base).appendingPathComponent("login-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            try atomicWrite(Data("cli_auth_credentials_store = \"file\"\n".utf8),
                            to: staging.appendingPathComponent("config.toml"))
            if let authorize { try authorize(staging) }
            else { try AppServerClient.authorize(home: staging, cancellation: cancellation) }
            try cancellation.check()
            let result: ProbeResult
            if let probe { result = try probe(staging) }
            else { result = try AppServerClient.probe(home: staging, cancellation: cancellation) }
            try cancellation.check()
            guard result.email?.caseInsensitiveCompare(account.email) == .orderedSame else {
                throw AuthSwitchError.identityMismatch
            }
            let data = try read(staging.appendingPathComponent("auth.json"), for: account)
            try cancellation.commit {
                try atomicWrite(data, to: slot(base: base, account: account))
                if reauthorize {
                    try atomicWrite(Data(), to: activationMarker(base: base, account: account))
                }
            }
        }
    }

    private static func activationMarker(base: URL, account: Account) -> URL {
        slot(base: base, account: account).deletingLastPathComponent().appendingPathComponent("pending-activation")
    }

    static func needsActivation(base: URL, account: Account) -> Bool {
        // The intent survives managed token rotation in this slot.
        hasSlot(base: base, account: account) && FileManager.default.fileExists(
            atPath: activationMarker(base: base, account: account).path)
    }

    /// The caller holds the vault lock for the entire database + credential deletion.
    static func removeSlotLocked(base: URL, account: Account) throws {
        let directory = slot(base: base, account: account).deletingLastPathComponent()
        // A persistent tombstone rejects stale work from another tool instance.
        try atomicWrite(Data(), to: root(base: base).appendingPathComponent("\(account.id.uuidString).deleted"))
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    static func ensureNotDeleted(base: URL, account: Account) throws {
        if FileManager.default.fileExists(atPath: root(base: base)
            .appendingPathComponent("\(account.id.uuidString).deleted").path) {
            throw AuthSwitchError.io("账号已删除，请重新打开账号列表")
        }
    }

    static func openMain(base: URL) throws {
        try withVaultLock(base: base) { try DesktopLauncher.openShared() }
    }

    /// Quit Codex first, save its latest refreshed tokens, then replace only auth.json.
    /// This method never changes the shared project, session, or state files.
    static func switchTo(base: URL, account: Account, allAccounts: [Account]) throws -> Bool {
        return try withVaultLock(base: base) {
            try switchLocked(base: base, account: account, allAccounts: allAccounts)
        }
    }

    private static func switchLocked(base: URL, account: Account,
                                     allAccounts: [Account]) throws -> Bool {
        try ensureNotDeleted(base: base, account: account)
        // Resolve configuration layering through Codex itself, before quitting
        // the desktop or touching its credentials. Unknown storage fails closed.
        try AppServerClient.requireFileStorage(home: sharedAuth.deletingLastPathComponent())
        let vault = root(base: base)
        let targetData = try read(slot(base: base, account: account), for: account)
        let current = activeAccount(accounts: allAccounts)
        if current?.id == account.id, !needsActivation(base: base, account: account) {
            try DesktopLauncher.openShared()
            return false
        }
        let currentBefore = try current.map { try read(sharedAuth, for: $0) }
        if let currentBefore, current?.id != account.id {
            guard try identity(from: currentBefore).accountID != identity(from: targetData).accountID else {
                throw AuthSwitchError.identityMismatch
            }
        }
        if DesktopLauncher.isolatedInstanceRunning() { throw AuthSwitchError.isolatedAppRunning }

        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.openai.codex" }
        for app in running { _ = app.terminate() }
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if DesktopLauncher.mainAppCommands().isEmpty { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard DesktopLauncher.mainAppCommands().isEmpty,
              running.allSatisfy({ $0.isTerminated }) else { throw AuthSwitchError.appStillRunning }

        // The app may refresh its token while quitting, so read the file again now.
        // If it removed or replaced the file, retain the last known good copy.
        let latest: Data?
        if let current {
            latest = (try? read(sharedAuth, for: current)) ?? currentBefore
            if let latest, current.id != account.id, !needsActivation(base: base, account: current) {
                try ensureNotDeleted(base: base, account: current)
                _ = try prepareSlot(base: base, account: current)
                try atomicWrite(latest, to: slot(base: base, account: current))
            }
        } else {
            latest = nil
        }
        if let raw = try? Data(contentsOf: sharedAuth),
           current == nil || (try? identity(from: raw).email.caseInsensitiveCompare(current!.email)) != .orderedSame {
            let recovery = vault.appendingPathComponent("recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recovery.path)
            try atomicWrite(raw, to: recovery.appendingPathComponent("auth-\(UUID().uuidString).json"))
        }
        // Recheck immediately before the commit in case the app was opened externally.
        guard DesktopLauncher.mainAppCommands().isEmpty else { throw AuthSwitchError.appStillRunning }
        try atomicWrite(targetData, to: sharedAuth)
        do {
            try DesktopLauncher.openShared()
        } catch {
            if let latest { try? atomicWrite(latest, to: sharedAuth) }
            throw error
        }
        try? FileManager.default.removeItem(at: activationMarker(base: base, account: account))
        return true
    }

    private static func atomicWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError("无法写入授权文件") }
        var closed = false
        defer {
            if !closed { Darwin.close(fd) }
            try? FileManager.default.removeItem(at: temporary)
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixError("授权文件写入失败") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw posixError("授权文件同步失败") }
        Darwin.close(fd)
        closed = true
        guard rename(temporary.path, destination.path) == 0 else { throw posixError("授权文件替换失败") }
        let dirFD = Darwin.open(directory.path, O_RDONLY)
        if dirFD >= 0 { _ = fsync(dirFD); Darwin.close(dirFD) }
    }

    private static func posixError(_ context: String) -> AuthSwitchError {
        .io("\(context)：\(String(cString: strerror(errno)))")
    }
}
