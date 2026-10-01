import Foundation

/// Reads rate limits using an existing desktop access token. The app-server
/// session is ephemeral and never receives a refresh token or writes auth.json.
enum ExternalQuota {
    static func probe(base: URL, account: Account) throws -> ProbeResult {
        guard FileManager.default.isExecutableFile(atPath: AppServerClient.bundledCLI) else {
            throw ProbeError.missingCLI
        }
        let credential = try AuthSwitcher.accessCredential(base: base, account: account)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-accounts-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.toml")
        try Data("cli_auth_credentials_store = \"ephemeral\"\n".utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)

        let rpc = try AppServerSession(home: home)
        defer { rpc.close() }
        _ = try rpc.request("account/login/start", params: [
            "type": "chatgptAuthTokens", "accessToken": credential.token,
            "chatgptAccountId": credential.accountID
        ])
        let limits = try rpc.request("account/rateLimits/read")
        return AppServerClient.decodedRateLimits(limits, email: credential.email, plan: nil)
    }
}
