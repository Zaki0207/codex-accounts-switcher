import AppKit
import SwiftUI

final class DashboardModel: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var busy: Set<UUID> = []
    @Published var switching: UUID?
    @Published var authorizingID: UUID?
    @Published var cancellingAuthorization = false
    private var authorizationCancellation: AuthorizationCancellation?
    @Published var exclusiveOperation: String?
    var canMutate: Bool { exclusiveOperation == nil && busy.isEmpty }
    @Published var activeID: UUID?
    @Published var notice = ""
    private let database: AccountDatabase?
    private var lastAttempt: [UUID: Date] = [:]
    private var failures: [UUID: Int] = [:]
    private var refreshTimer: Timer?

    init(database: AccountDatabase? = try? AccountDatabase(), automaticRefresh: Bool = true) {
        self.database = database
        accounts = database?.load() ?? []
        if database == nil { notice = "无法打开本地数据库" }
        guard automaticRefresh else { return }
        activeID = AuthSwitcher.activeAccount(accounts: accounts)?.id
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
    }

    deinit { refreshTimer?.invalidate() }

    func paths(for account: Account) -> ProfilePaths? {
        database.map { ProfilePaths(base: $0.base, id: account.id) }
    }

    func mfaURL(for account: Account) -> String { MFAKeychain.read(for: account.id) ?? "" }

    func save(id: UUID?, name: String, email: String, url: String) -> Bool {
        guard canMutate else { notice = "请等待当前操作完成后再编辑账号"; return false }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanEmail.contains("@"),
              let target = URL(string: cleanURL),
              target.scheme?.lowercased() == "https",
              target.host != nil else {
            notice = "请填写名称、邮箱和有效的 HTTPS 取码网址"
            return false
        }
        guard let database else { notice = "数据库不可用"; return false }
        let accountID = id ?? UUID()
        let old = accounts.first { $0.id == accountID }
        if accounts.contains(where: { $0.email == cleanEmail && $0.id != accountID }) {
            notice = "这个邮箱已经添加"
            return false
        }
        guard MFAKeychain.save(cleanURL, for: accountID) else {
            notice = "取码网址无法写入钥匙串"
            return false
        }
        var account = old ?? Account(id: accountID, name: cleanName, email: cleanEmail,
                                     snapshot: nil, error: nil)
        account.name = cleanName
        account.email = cleanEmail
        if old?.email != cleanEmail { account.snapshot = nil }
        account.error = nil
        do {
            try ProfilePaths(base: database.base, id: accountID).prepare()
            try database.save(account)
            if let index = accounts.firstIndex(where: { $0.id == accountID }) { accounts[index] = account }
            else { accounts.append(account) }
            activeID = AuthSwitcher.activeAccount(accounts: accounts)?.id
            notice = "已保存账号。点击“保存桌面授权”登录一次，即可切换账号并读取额度。"
            return true
        } catch {
            notice = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    func delete(_ account: Account) {
        guard canMutate, let database, let paths = paths(for: account),
              accounts.contains(where: { $0.id == account.id }) else { return }
        if DesktopLauncher.isRunning(browser: paths.browser) {
            notice = "请先关闭这个账号的 Codex 窗口再删除"
            return
        }
        exclusiveOperation = "delete"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try AuthSwitcher.withVaultLock(base: database.base) {
                    try AuthSwitcher.removeSlotLocked(base: database.base, account: account)
                    try database.delete(account.id)
                    MFAKeychain.delete(for: account.id)
                }
            }
            DispatchQueue.main.async {
                self.exclusiveOperation = nil
                switch result {
                case .success:
                    self.accounts.removeAll { $0.id == account.id }
                    self.lastAttempt.removeValue(forKey: account.id)
                    self.failures.removeValue(forKey: account.id)
                    self.activeID = AuthSwitcher.activeAccount(accounts: self.accounts)?.id
                    self.notice = "已移除账号及保存的桌面授权；项目和聊天记录未改动。"
                case .failure(let error): self.notice = "删除失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func refreshAll(force: Bool = false) {
        for account in accounts { refresh(account, force: force) }
    }

    func refresh(_ account: Account, force: Bool = true) {
        guard exclusiveOperation == nil, let paths = paths(for: account), !busy.contains(account.id),
              accounts.contains(where: { $0.id == account.id && $0.email == account.email }) else { return }
        let failureCount = min(failures[account.id] ?? 0, 3)
        let retryDelay = min(3600.0, 900.0 * pow(2.0, Double(failureCount)))
        if !force, let previous = lastAttempt[account.id], Date().timeIntervalSince(previous) < retryDelay { return }
        lastAttempt[account.id] = Date()
        busy.insert(account.id)
        let accountBase = database?.base
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try Self.probeQuota(for: account, profileHome: paths.codexHome,
                                                      base: accountBase) }
            DispatchQueue.main.async {
                self.busy.remove(account.id)
                guard let index = self.accounts.firstIndex(where: { $0.id == account.id }) else { return }
                switch result {
                case .success(let probe):
                    if let actual = probe.email,
                       actual.caseInsensitiveCompare(self.accounts[index].email) != .orderedSame {
                        self.accounts[index].error = "登录身份不符：\(actual)。请检查账号邮箱。"
                        self.failures[account.id, default: 0] += 1
                    } else if let snapshot = probe.snapshot {
                        self.accounts[index].snapshot = snapshot
                        self.accounts[index].error = nil
                        self.failures[account.id] = 0
                    } else if let rateError = probe.rateError {
                        self.accounts[index].error = "额度读取失败：\(rateError)"
                        self.failures[account.id, default: 0] += 1
                    } else {
                        self.accounts[index].error = "尚未登录"
                        self.failures[account.id, default: 0] += 1
                    }
                case .failure(let error):
                    self.accounts[index].error = error.localizedDescription
                    self.failures[account.id, default: 0] += 1
                }
                try? self.database?.save(self.accounts[index])
            }
        }
    }

    func openMain() {
        guard canMutate, let database else { return }
        exclusiveOperation = "open"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AuthSwitcher.openMain(base: database.base) }
            DispatchQueue.main.async {
                self.exclusiveOperation = nil
                switch result {
                case .success: self.notice = "已打开主 Codex。账号切换请使用对应账号卡片的按钮。"
                case .failure(let error): self.notice = error.localizedDescription
                }
            }
        }
    }

    func hasDesktopAuth(_ account: Account) -> Bool {
        guard let database else { return false }
        return AuthSwitcher.hasSlot(base: database.base, account: account)
    }

    func needsActivation(_ account: Account) -> Bool {
        guard let database else { return false }
        return AuthSwitcher.needsActivation(base: database.base, account: account)
    }

    func saveDesktopAuth(_ account: Account, reauthorize: Bool = false) {
        guard canMutate, let database,
              accounts.contains(where: { $0.id == account.id && $0.email == account.email }) else { return }
        exclusiveOperation = "authorize"
        authorizingID = account.id
        cancellingAuthorization = false
        let cancellation = AuthorizationCancellation()
        authorizationCancellation = cancellation
        busy.insert(account.id)
        notice = "正在为 \(account.name) 保存桌面授权。请在官方网页完成登录和验证。"
        let allAccounts = accounts
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try AuthSwitcher.capture(base: database.base, account: account, allAccounts: allAccounts,
                                         reauthorize: reauthorize, cancellation: cancellation)
            }
            DispatchQueue.main.async {
                self.busy.remove(account.id)
                self.exclusiveOperation = nil
                self.authorizingID = nil
                self.cancellingAuthorization = false
                self.authorizationCancellation = nil
                guard self.accounts.contains(where: { $0.id == account.id && $0.email == account.email }) else { return }
                switch result {
                case .success:
                    self.notice = "已保存 \(account.name) 的桌面授权。请点击切换以应用新授权。"
                    self.refresh(account, force: true)
                case .failure(let error):
                    if case ProbeError.cancelled = error {
                        self.notice = "已取消 \(account.name) 的授权，原有授权已保留。"
                    } else {
                        self.notice = "保存桌面授权失败：\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func cancelAuthorization(_ account: Account) {
        guard authorizingID == account.id, !cancellingAuthorization,
              let cancellation = authorizationCancellation, cancellation.cancel() else { return }
        cancellingAuthorization = true
        notice = "正在取消 \(account.name) 的授权…"
        // Keep operations disabled until the child exits and staging files are removed.
    }

    func switchAccount(_ account: Account) {
        guard canMutate, let database,
              accounts.contains(where: { $0.id == account.id && $0.email == account.email }) else { return }
        exclusiveOperation = "switch"
        switching = account.id
        notice = "正在退出主 Codex、保存当前授权并切换到 \(account.name)…"
        let allAccounts = accounts
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try AuthSwitcher.switchTo(base: database.base, account: account, allAccounts: allAccounts)
            }
            DispatchQueue.main.async {
                self.switching = nil
                self.exclusiveOperation = nil
                self.activeID = AuthSwitcher.activeAccount(accounts: self.accounts)?.id
                switch result {
                case .success(let changed):
                    self.notice = changed
                        ? "已替换为 \(account.name) 的授权并启动主 Codex。请核对应用内账号。"
                        : "\(account.name) 已是当前账号。"
                case .failure(let error):
                    self.notice = "切换失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private static func probeQuota(for account: Account, profileHome: URL, base: URL?) throws -> ProbeResult {
        if let base, AuthSwitcher.hasSlot(base: base, account: account)
            || AuthSwitcher.activeAccount(accounts: [account])?.id == account.id {
            do {
                return try ExternalQuota.probe(base: base, account: account)
            } catch {
                // Only an inactive account can refresh its saved file here. The
                // desktop app owns the active file while it is running.
                if AuthSwitcher.activeAccount(accounts: [account])?.id == account.id { throw error }
                return try AuthSwitcher.withVaultLock(base: base) {
                    try AuthSwitcher.ensureNotDeleted(base: base, account: account)
                    if AuthSwitcher.activeAccount(accounts: [account])?.id == account.id {
                        return try ExternalQuota.probe(base: base, account: account)
                    }
                    let home = try AuthSwitcher.prepareSlot(base: base, account: account)
                    let renewed = try AppServerClient.probe(home: home)
                    guard renewed.email?.caseInsensitiveCompare(account.email) == .orderedSame else {
                        throw AuthSwitchError.identityMismatch
                    }
                    return renewed
                }
            }
        }
        let profile = try? AppServerClient.probe(home: profileHome)
        if let profile, profile.email?.caseInsensitiveCompare(account.email) == .orderedSame,
           profile.snapshot != nil { return profile }
        if let profile, profile.email?.caseInsensitiveCompare(account.email) == .orderedSame { return profile }
        throw ProbeError.server("请先保存桌面授权，随后即可读取额度")
    }

    func openMFA(_ account: Account) {
        guard let text = MFAKeychain.read(for: account.id), let url = URL(string: text) else {
            notice = "请先为这个账号填写取码网址"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(account.email, forType: .string)
        guard NSWorkspace.shared.open(url) else {
            notice = "无法打开取码网页"
            return
        }
        notice = "已打开取码网页，账号邮箱已复制到剪贴板"
    }

}

private func beijingDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter.string(from: date)
}

private func beijingExpiryDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy年M月d日 HH:mm"
    return formatter.string(from: date)
}

private func countdown(_ reset: Date, now: Date) -> String {
    let seconds = max(0, Int(reset.timeIntervalSince(now)))
    if seconds == 0 { return "即将重置" }
    let days = seconds / 86400, hours = (seconds % 86400) / 3600, minutes = (seconds % 3600) / 60
    return days > 0 ? "\(days)天\(hours)小时" : "\(hours)小时\(minutes)分"
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @State private var editingID: UUID?
    @State private var showEditor = false
    @State private var name = ""
    @State private var email = ""
    @State private var mfaURL = ""
    @State private var deleting: Account?
    @State private var now = Date()
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex 账号").font(.title2.bold())
                    Text("共用原本地记录 · 北京时间").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("打开 Codex") { model.openMain() }
                    .disabled(!model.canMutate)
                    .help("打开主 Codex；不会切换账号")
                Button { model.refreshAll(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                }.help("刷新全部额度").disabled(model.exclusiveOperation != nil)
                Button { beginAdd() } label: {
                    Image(systemName: "plus")
                }.help("添加账号").disabled(!model.canMutate)
            }

            if showEditor { editor }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.accounts.isEmpty && !showEditor {
                        ContentUnavailableView("还没有账号", systemImage: "person.crop.circle.badge.plus",
                                               description: Text("点击右上角＋添加账号和取码网址"))
                            .frame(maxWidth: .infinity, minHeight: 230)
                    }
                    ForEach(model.accounts) { account in
                        accountCard(account)
                    }
                }
            }
            if !model.notice.isEmpty {
                Text(model.notice).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("一次桌面授权可用于切换与额度读取")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.caption)
            }
        }
        .padding(16)
        .frame(width: 460, height: 560)
        .onAppear {
            if !loaded { loaded = true; model.refreshAll(force: true) }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .confirmationDialog("删除 \(deleting?.name ?? "账号")？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("从列表移除账号", role: .destructive) {
                if let deleting { model.delete(deleting) }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("将移除账号卡片、保存的桌面授权和取码网址。共享项目、聊天及旧版独立账号目录均保留；当前桌面登录不会立即退出。")
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(editingID == nil ? "添加账号" : "编辑账号").font(.headline)
            TextField("名称，例如工作账号", text: $name)
            TextField("登录邮箱", text: $email)
            SecureField("取码网页地址（可含访问密钥）", text: $mfaURL)
            HStack {
                Text("网址保存在 macOS 钥匙串").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { showEditor = false }
                Button("保存") {
                    if model.save(id: editingID, name: name, email: email, url: mfaURL) {
                        showEditor = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(!model.canMutate)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func accountCard(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.name).font(.headline).lineLimit(1).layoutPriority(1)
                Spacer()
                if model.busy.contains(account.id) { ProgressView().controlSize(.small) }
                else if account.error == nil && account.snapshot != nil {
                    Label("有效", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
                if model.authorizingID == account.id {
                    Button(model.cancellingAuthorization ? "取消中…" : "取消授权") {
                        model.cancelAuthorization(account)
                    }
                    .disabled(model.cancellingAuthorization)
                    .help("停止本次登录等待，保留原有授权")
                }
                Button("编辑") { beginEdit(account) }.disabled(!model.canMutate)
                Menu {
                    Button("重新授权…") { model.saveDesktopAuth(account, reauthorize: true) }
                    Button("从列表移除账号", role: .destructive) { deleting = account }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!model.canMutate)
                .help("账号操作")
            }.controlSize(.small)
            Text(account.email).font(.caption).foregroundStyle(.secondary)
            if model.activeID == account.id {
                Label("当前桌面授权", systemImage: "person.crop.circle.fill")
                    .font(.caption2).foregroundStyle(.blue)
            }
            if model.needsActivation(account) {
                Text("新授权已保存，点击切换后应用").font(.caption2).foregroundStyle(.orange)
            }
            if let snapshot = account.snapshot {
                ForEach(snapshot.buckets.filter { bucket in
                    bucket.id.caseInsensitiveCompare("gpt-reserve") != .orderedSame &&
                    bucket.name.caseInsensitiveCompare("gpt-reserve") != .orderedSame
                }) { bucket in
                    if !bucket.windows.isEmpty {
                        Text(bucket.name).font(.caption.bold())
                        ForEach(bucket.windows.indices, id: \.self) { index in
                            let window = bucket.windows[index]
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("\(window.label) · 剩余 \(Int(max(0, 100 - window.usedPercent)))%")
                                    Spacer()
                                    if let reset = window.resetsAt {
                                        Text("\(countdown(reset, now: now)) · \(beijingDate(reset))")
                                    }
                                }.font(.caption2).foregroundStyle(.secondary)
                                ProgressView(value: max(0, min(1, (100 - window.usedPercent) / 100)))
                                    .tint(window.usedPercent >= 90 ? .orange : .blue)
                            }
                        }
                    }
                }
                if let resetCredits = snapshot.resetCredits {
                    HStack {
                        Label("重置卡", systemImage: "arrow.counterclockwise.circle")
                            .font(.caption.bold())
                        Spacer()
                        Text("可用 \(resetCredits.availableCount) 张")
                            .font(.caption)
                    }
                    if resetCredits.availableCount > 0 {
                        if let credits = resetCredits.credits {
                            let expiries = Array(credits.compactMap(\.expiresAt).sorted().prefix(3))
                            ForEach(expiries.indices, id: \.self) { index in
                                Text("到期：\(beijingExpiryDate(expiries[index]))（北京时间）")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if credits.compactMap(\.expiresAt).count > expiries.count {
                                Text("其余到期时间未展开")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if expiries.isEmpty {
                                Text("到期时间未提供")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if credits.count < resetCredits.availableCount {
                                Text("另有 \(resetCredits.availableCount - credits.count) 张未返回明细")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("到期时间未提供").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack {
                        Label("重置卡", systemImage: "arrow.counterclockwise.circle")
                            .font(.caption.bold())
                        Spacer()
                        Text("数据未提供").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("更新：\(beijingDate(snapshot.fetchedAt))\(Date().timeIntervalSince(snapshot.fetchedAt) > 1800 ? " · 旧数据" : "")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if let error = account.error {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
            } else if account.snapshot == nil {
                Text("尚未读取额度").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if model.hasDesktopAuth(account) {
                    Button(model.switching == account.id ? "切换中…" : "切换到此账号") {
                        model.switchAccount(account)
                    }
                    .disabled(!model.canMutate)
                    .help("退出并重启同一个 Codex，仅替换默认 auth.json")
                } else {
                    Button("保存桌面授权") { model.saveDesktopAuth(account) }
                        .disabled(!model.canMutate)
                        .help("通过官方网页登录一次，保存该账号的文件授权")
                }
                Button("取码网页") { model.openMFA(account) }
                Button("刷新") { model.refresh(account) }
                    .disabled(model.exclusiveOperation != nil || model.busy.contains(account.id))
                Spacer()

            }.controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func beginAdd() {
        editingID = nil; name = ""; email = ""; mfaURL = ""; showEditor = true
    }

    private func beginEdit(_ account: Account) {
        editingID = account.id; name = account.name; email = account.email
        mfaURL = model.mfaURL(for: account); showEditor = true
    }
}

#if REVIEW_TEST
// The regression test executable supplies its own entry point.
#elseif PREVIEW
@main
struct CodexAccountsPreviewApp: App {
    @StateObject private var model = DashboardModel()

    var body: some Scene {
        WindowGroup("Codex 账号") { DashboardView(model: model) }
    }
}
#else
@main
struct CodexAccountsApp: App {
    @StateObject private var model = DashboardModel()

    var body: some Scene {
        MenuBarExtra("Codex 账号", systemImage: "person.2.circle.fill") {
            DashboardView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
