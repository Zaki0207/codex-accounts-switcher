import Foundation
import Darwin

/// One bounded stdio connection. Server requests and client responses have
/// independent ID spaces; classify by method before comparing IDs.
final class AppServerSession {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var deadline: DispatchWorkItem?
    private var nextID = 1
    private let cancellation: AuthorizationCancellation?

    init(home: URL, timeout: TimeInterval = 18, cancellation: AuthorizationCancellation? = nil) throws {
        self.cancellation = cancellation
        try cancellation?.check()
        guard FileManager.default.isExecutableFile(atPath: AppServerClient.bundledCLI) else {
            throw ProbeError.missingCLI
        }
        process = Process()
        process.executableURL = URL(fileURLWithPath: AppServerClient.bundledCLI)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = home
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        cancellation?.attach(process)
        let child = process
        // SIGKILL bounds blocked reads as well as shutdown; only this child is killed.
        let timeoutWork = DispatchWorkItem {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        deadline = timeoutWork
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        do {
            _ = try request("initialize", params: [
                "clientInfo": ["name": "codex_accounts_menu", "title": "Codex Accounts", "version": "0.6.1"],
                "capabilities": ["experimentalApi": true]
            ])
            try send(["method": "initialized", "params": [:]])
        } catch {
            close()
            throw error
        }
    }

    func close() {
        try? input.close()
        if process.isRunning { process.terminate() }
        // Keep the deadline armed until the child has exited, so locks never
        // outlive an unbounded wait and no writer survives lock release.
        process.waitUntilExit()
        cancellation?.detach(process)
        deadline?.cancel()
        deadline = nil
        try? output.close()
    }

    func send(_ message: [String: Any]) throws {
        try cancellation?.check()
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.write(contentsOf: data)
    }

    func readMessage() throws -> [String: Any] {
        try cancellation?.check()
        var line = Data()
        while line.count < 2_000_000 {
            let byte = output.readData(ofLength: 1)
            if byte.isEmpty {
                try cancellation?.check()
                throw ProbeError.timeout
            }
            if byte[0] == 10 { break }
            line.append(byte)
        }
        guard line.count < 2_000_000,
              let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw ProbeError.malformedReply
        }
        return message
    }

    @discardableResult
    func handleServerRequest(_ message: [String: Any]) throws -> Bool {
        try RPCMessage.handleRequest(message, send: send)
    }

    func request(_ method: String, params: [String: Any]? = nil) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        try send(message)
        for _ in 0..<1000 {
            let reply = try readMessage()
            if try handleServerRequest(reply) { continue }
            if let result = try RPCMessage.response(reply, id: id) { return result }
        }
        throw ProbeError.malformedReply
    }
}

enum RPCMessage {
    static func handleRequest(_ message: [String: Any], send: ([String: Any]) throws -> Void) throws -> Bool {
        guard let method = message["method"] as? String else { return false }
        guard let id = message["id"], !(id is NSNull) else { return true } // notification
        let refresh = method == "account/chatgptAuthTokens/refresh"
        try send(["id": id, "error": [
            "code": refresh ? -32001 : -32601,
            "message": refresh ? "External token renewal requires a new session" : "Unsupported server request"
        ]])
        if refresh { throw ProbeError.server("桌面授权需要续期；当前账号请在主 Codex 中登录，或点击重新授权") }
        return true
    }

    static func response(_ message: [String: Any], id: Int) throws -> [String: Any]? {
        guard message["method"] == nil, message["id"] as? Int == id else { return nil }
        if let error = message["error"] as? [String: Any] {
            throw ProbeError.server(error["message"] as? String ?? "Codex 请求失败")
        }
        guard message["error"] == nil, let result = message["result"] as? [String: Any] else {
            throw ProbeError.malformedReply
        }
        return result
    }
}

/// One authorization attempt owns at most one child at a time. Cancellation
/// also fences the final credential commit, including the gap between children.
final class AuthorizationCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var committed = false
    private var process: Process?

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw ProbeError.cancelled }
    }

    func attach(_ child: Process) {
        lock.lock()
        defer { lock.unlock() }
        process = child
        if cancelled, child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }

    func detach(_ child: Process) {
        lock.lock()
        defer { lock.unlock() }
        if process === child { process = nil }
    }

    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !committed else { return false }
        cancelled = true
        if let child = process, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        return true
    }

    func commit(_ action: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw ProbeError.cancelled }
        try action()
        committed = true
    }
}
