import AppKit
import Foundation

enum ProbeError: LocalizedError {
    case missingCLI, timeout, malformedReply, cancelled, server(String)

    var errorDescription: String? {
        switch self {
        case .missingCLI: return "找不到 Codex CLI"
        case .cancelled: return "已取消授权"
        case .timeout: return "读取额度超时"
        case .malformedReply: return "Codex 返回了无法识别的数据"
        case .server(let message): return message
        }
    }
}

struct ProbeResult {
    let email: String?
    let snapshot: RateSnapshot?
    let rateError: String?
}

enum AppServerClient {
    static let bundledCLI = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"

    static func authorize(home: URL, cancellation: AuthorizationCancellation? = nil) throws {
        let rpc = try AppServerSession(home: home, timeout: 300, cancellation: cancellation)
        defer { rpc.close() }
        let start = try rpc.request("account/login/start", params: ["type": "chatgpt", "useHostedLoginSuccessPage": true, "appBrand": "codex"])
        guard let text = start["authUrl"] as? String, let url = URL(string: text),
              url.scheme == "https", let loginID = start["loginId"] as? String else {
            throw ProbeError.malformedReply
        }
        let opened = try DispatchQueue.main.sync {
            try cancellation?.check()
            return NSWorkspace.shared.open(url)
        }
        guard opened else { throw ProbeError.server("无法打开官方登录网页") }
        while true {
            let message = try rpc.readMessage()
            if try rpc.handleServerRequest(message) { continue }
            guard message["method"] as? String == "account/login/completed",
                  let params = message["params"] as? [String: Any],
                  params["loginId"] as? String == loginID else { continue }
            guard params["success"] as? Bool == true else {
                throw ProbeError.server(params["error"] as? String ?? "登录未完成")
            }
            return
        }
    }

    static func requireFileStorage(home: URL) throws {
        let rpc = try AppServerSession(home: home)
        defer { rpc.close() }
        let reply = try rpc.request("config/read", params: ["includeLayers": false])
        try validateFileStorage(reply)
    }

    static func validateFileStorage(_ reply: [String: Any]) throws {
        guard let config = reply["config"] as? [String: Any],
              config["cli_auth_credentials_store"] as? String == "file" else {
            throw ProbeError.server("主 Codex 未明确使用 file 授权存储。请在主配置中设置 cli_auth_credentials_store = \"file\" 后重试；工具不会修改钥匙串或自动迁移凭据。")
        }
    }

    static func probe(home: URL, cancellation: AuthorizationCancellation? = nil) throws -> ProbeResult {
        let rpc = try AppServerSession(home: home, cancellation: cancellation)
        defer { rpc.close() }
        let accountReply = try rpc.request("account/read", params: ["refreshToken": false])
        guard let account = accountReply["account"] as? [String: Any] else {
            return ProbeResult(email: nil, snapshot: nil, rateError: nil)
        }
        guard account["type"] as? String == "chatgpt",
              let email = account["email"] as? String, !email.isEmpty else {
            throw ProbeError.server("当前登录不是可核验邮箱的 ChatGPT 账号")
        }
        do {
            let limits = try rpc.request("account/rateLimits/read")
            return decodedRateLimits(limits, email: email, plan: account["planType"] as? String)
        } catch {
            return ProbeResult(email: email, snapshot: nil, rateError: error.localizedDescription)
        }
    }

    static func decodedRateLimits(_ limits: [String: Any], email: String, plan: String?) -> ProbeResult {
        guard limits["rateLimits"] is [String: Any] || limits["rateLimitsByLimitId"] is [String: Any] else {
            return ProbeResult(email: email, snapshot: nil, rateError: "额度响应缺少额度字段")
        }
        let rawBuckets: [String: Any]
        if let multi = limits["rateLimitsByLimitId"] as? [String: Any], !multi.isEmpty {
            rawBuckets = multi
        } else if let single = limits["rateLimits"] as? [String: Any] {
            rawBuckets = [single["limitId"] as? String ?? "codex": single]
        } else {
            rawBuckets = [:]
        }
        let buckets = rawBuckets.compactMap { key, value -> QuotaBucket? in
            guard let bucket = value as? [String: Any] else { return nil }
            var windows: [QuotaWindow] = []
            for (field, label) in [("primary", "主窗口"), ("secondary", "次窗口")] {
                guard let window = bucket[field] as? [String: Any],
                      let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { continue }
                let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue ?? 0
                let reset = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                windows.append(QuotaWindow(label: label, usedPercent: used,
                                           durationMins: minutes, resetsAt: reset))
            }
            return QuotaBucket(id: key, name: bucket["limitName"] as? String ?? key, windows: windows)
        }.sorted { $0.id != $1.id && ($0.id == "codex" || ($1.id != "codex" && $0.id < $1.id)) }
        let resetCredits: ResetCreditSummary?
        if let raw = limits["rateLimitResetCredits"] as? [String: Any],
           let count = (raw["availableCount"] as? NSNumber)?.intValue {
            let credits = (raw["credits"] as? [[String: Any]])?.compactMap { item -> ResetCreditDetail? in
                guard item["status"] as? String == "available" else { return nil }
                let expiry = (item["expiresAt"] as? NSNumber)
                    .map { Date(timeIntervalSince1970: $0.doubleValue) }
                return ResetCreditDetail(expiresAt: expiry)
            }
            resetCredits = ResetCreditSummary(availableCount: max(0, count), credits: credits)
        } else {
            resetCredits = nil
        }
        return ProbeResult(email: email,
                           snapshot: RateSnapshot(email: email,
                                                  plan: plan,
                                                  buckets: buckets,
                                                  resetCredits: resetCredits,
                                                  fetchedAt: Date()),
                           rateError: nil)
    }
}

enum DesktopLauncher {
    private static let appPath = "/Applications/ChatGPT.app"

    static func openShared() throws {
        guard FileManager.default.fileExists(atPath: appPath) else {
            throw ProbeError.server("找不到 /Applications/ChatGPT.app")
        }
        if isolatedInstanceRunning() {
            throw ProbeError.server("检测到独立数据目录的 Codex 窗口。请先完成其中的任务并退出该窗口，再打开主 Codex。")
        }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.openai.codex" }
        if let existing = apps.first(where: { !$0.isTerminated }),
           existing.activate(options: [.activateAllWindows]) {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appPath]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CODEX_HOME")
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw ProbeError.server("无法启动 Codex 桌面 App") }
    }

    static func isRunning(browser: URL) -> Bool {
        mainAppCommands().contains { $0.contains("--user-data-dir=\(browser.path)") }
    }

    static func isolatedInstanceRunning() -> Bool {
        mainAppCommands().contains(where: isIsolatedCommand)
    }

    static func isIsolatedCommand(_ command: String) -> Bool {
        command.hasPrefix(appPath + "/Contents/MacOS/ChatGPT") && command.contains("--user-data-dir=")
    }

    static func mainAppCommands() -> [String] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-ww", "-axo", "command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }
        let commands = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ps.waitUntilExit()
        let prefix = appPath + "/Contents/MacOS/ChatGPT"
        return commands.split(separator: "\n").map(String.init).filter { $0.hasPrefix(prefix) }
    }
}
