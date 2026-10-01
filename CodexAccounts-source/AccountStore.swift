import Foundation
import Security
import SQLite3

struct QuotaWindow: Codable {
    let label: String
    let usedPercent: Double
    let durationMins: Int
    let resetsAt: Date?
}

struct QuotaBucket: Codable, Identifiable {
    let id: String
    let name: String
    let windows: [QuotaWindow]
}

struct ResetCreditDetail: Codable {
    let expiresAt: Date?
}

struct ResetCreditSummary: Codable {
    let availableCount: Int
    let credits: [ResetCreditDetail]?
}

struct RateSnapshot: Codable {
    let email: String
    let plan: String?
    let buckets: [QuotaBucket]
    let resetCredits: ResetCreditSummary?
    let fetchedAt: Date
}

struct Account: Identifiable {
    let id: UUID
    var name: String
    var email: String
    var snapshot: RateSnapshot?
    var error: String?
}

struct ProfilePaths {
    let root: URL
    let codexHome: URL
    let browser: URL

    init(base: URL, id: UUID) {
        root = base.appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        browser = root.appendingPathComponent("browser", isDirectory: true)
    }

    func prepare() throws {
        for directory in [root, codexHome, browser] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let config = codexHome.appendingPathComponent("config.toml")
        if !FileManager.default.fileExists(atPath: config.path) {
            try Data("cli_auth_credentials_store = \"keyring\"\n".utf8).write(to: config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        }
    }
}

enum MFAKeychain {
    private static let service = "com.codexaccounts.mfa-url"

    static func save(_ value: String, for id: UUID) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        let data = Data(value.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
            return true
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func read(for id: UUID) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for id: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
    }
}

final class AccountDatabase {
    let base: URL
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(base directory: URL? = nil) throws {
        base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Accounts", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        let path = base.appendingPathComponent("accounts.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw DBError.open }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL, snapshot TEXT, error TEXT)")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    deinit { sqlite3_close(db) }

    enum DBError: Error { case open, sql }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DBError.sql }
    }

    func load() -> [Account] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT id,name,email,snapshot,error FROM accounts ORDER BY rowid", -1, &statement, nil) == SQLITE_OK else { return [] }
        var result: [Account] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: idText)) else { continue }
            let name = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let email = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let snapshot: RateSnapshot? = sqlite3_column_text(statement, 3).flatMap {
                try? JSONDecoder().decode(RateSnapshot.self, from: Data(String(cString: $0).utf8))
            }
            let error = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            result.append(Account(id: id, name: name, email: email, snapshot: snapshot, error: error))
        }
        return result
    }

    func save(_ account: Account) throws {
        let sql = "INSERT INTO accounts(id,name,email,snapshot,error) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,email=excluded.email,snapshot=excluded.snapshot,error=excluded.error"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw DBError.sql }
        bind(account.id.uuidString, at: 1, in: statement)
        bind(account.name, at: 2, in: statement)
        bind(account.email, at: 3, in: statement)
        if let snapshot = account.snapshot, let data = try? JSONEncoder().encode(snapshot),
           let json = String(data: data, encoding: .utf8) {
            bind(json, at: 4, in: statement)
        } else { sqlite3_bind_null(statement, 4) }
        if let error = account.error { bind(error, at: 5, in: statement) }
        else { sqlite3_bind_null(statement, 5) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DBError.sql }
    }

    func delete(_ id: UUID) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "DELETE FROM accounts WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw DBError.sql }
        bind(id.uuidString, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DBError.sql }
    }

    private func bind(_ value: String, at position: Int32, in statement: OpaquePointer?) {
        value.withCString { pointer in
            _ = sqlite3_bind_text(statement, position, pointer, -1, transient)
        }
    }
}
