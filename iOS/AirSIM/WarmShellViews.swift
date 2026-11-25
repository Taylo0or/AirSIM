import SwiftUI
import UIKit

// AirSIM 的 App 外壳。结构来自 Codex 设计稿（docs/design/warm-2026-11-20/DESIGN.md），
// 视觉按 2026-11-25 修订（同目录 REVISION-2026-11-25.md）：中性系统灰、强调色只标选中与链接、
// 信息靠排版分层，不靠卡片、色块和图标。通话界面、短信会话页、设置子页面沿用原有实现。

// MARK: - Tokens

enum Warm {
    static var accent: Color { Color(uiColor: AppTheme.current.uiAccent) }
    static let background = Color(uiColor: WarmPalette.background)
    static let plain = Color(uiColor: WarmPalette.plain)
    static let surface = Color(uiColor: WarmPalette.card)
    static let raised = Color(uiColor: WarmPalette.raised)
    static let muted = Color(uiColor: WarmPalette.soft)
    static let call = Color(uiColor: WarmPalette.call)
    static let avatar = Color(uiColor: WarmPalette.avatar)
    static let text = Color(uiColor: WarmPalette.textPrimary)
    static let secondary = Color(uiColor: WarmPalette.textSecondary)
    static let disabled = Color(uiColor: WarmPalette.textDisabled)
    static var onAccent: Color { Color(uiColor: WarmPalette.onAccent) }
    static var accentSoft: Color { Color(uiColor: WarmPalette.accentSoft) }
    static let separator = Color(uiColor: WarmPalette.cardBorder)
    static let controlBorder = Color(uiColor: WarmPalette.controlBorder)
    static let positive = Color(uiColor: WarmPalette.positive)
    static let danger = Color(uiColor: WarmPalette.danger)
    static let warningText = Color(uiColor: WarmPalette.warningText)
    static let warningSurface = Color(uiColor: WarmPalette.warningSurface)
    static let disabledFill = Color(uiColor: WarmPalette.disabledFill)
}

extension View {
    /// Grouped cell block (line board, settings groups): radius 12, no border, no shadow.
    func warmCard(_ radius: CGFloat = 12) -> some View { modifier(WarmCardSurface(cornerRadius: radius)) }

    /// A row of the shell's plain Lists (recents, voicemail, messages): own insets, plain background,
    /// and the system separator only where `separator` asks for one.
    func warmListRow(leading: CGFloat = 20, trailing: CGFloat = 20, separator: Bool = false) -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing))
            .listRowBackground(Warm.plain)
            .listRowSeparator(separator ? .visible : .hidden, edges: separator ? .bottom : .all)
            .listRowSeparatorTint(Warm.separator)
    }

    /// The List itself: plain style on the page's own background, rows as tall as their content.
    func warmPlainList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Warm.plain)
            .environment(\.defaultMinListRowHeight, 1)
    }
}

/// One physical pixel separator.
struct WarmHairline: View {
    @Environment(\.displayScale) private var scale
    var body: some View { Rectangle().fill(Warm.separator).frame(height: 1 / max(scale, 1)) }
}

// MARK: - Numbers, lines and labels

enum WarmPhone {
    static func digits(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.isASCII && CharacterSet.decimalDigits.contains($0) })
    }

    static func isNANP(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let number = digits(trimmed)
        if trimmed.hasPrefix("+1") { return number.count == 11 }
        if trimmed.hasPrefix("+") { return false }
        return number.count == 10 && number.first.map { $0 != "0" && $0 != "1" } == true
    }

    /// "+1 236 555 0102", "+86 138 0000 0000" / "138 0000 0000"; short codes stay as given.
    static func format(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "号码未知" }
        let number = digits(raw)
        if isNANP(raw) {
            let d = Array(number.suffix(10))
            return "+1 \(String(d[0..<3])) \(String(d[3..<6])) \(String(d[6..<10]))"
        }
        let international = raw.hasPrefix("+86")
        let mainland = international ? String(number.dropFirst(2)) : number
        if mainland.count == 11, mainland.hasPrefix("1"), international || !raw.hasPrefix("+") {
            let d = Array(mainland)
            return "\(international ? "+86 " : "")\(String(d[0..<3])) \(String(d[3..<7])) \(String(d[7..<11]))"
        }
        return raw
    }

    @MainActor static func name(_ number: String?, contacts: ContactStore) -> String {
        guard let number, !number.isEmpty else { return "号码未知" }
        return contacts.contact(for: number)?.name ?? format(number)
    }
}

/// A callable / textable line: one SIM slot of an Android Agent or one voip.ms DID.
struct WarmLine: Identifiable, Equatable {
    let agentID: String
    let slotID: String?
    let slotIndex: Int?
    let number: String?
    let deviceName: String
    let carrier: String?
    let isVoipms: Bool
    let route: String
    let online: Bool
    /// Fresh 0–4 bars; nil when unknown or stale (never shown as zero bars).
    var signal: Int? = nil
    var id: String { "\(agentID)|\(slotID ?? "-")" }
    var title: String { number.map { WarmPhone.format($0) } ?? "号码未知" }
    /// "voip.ms", "家中 K40 · 中国移动 · SIM 1".
    var source: String {
        if isVoipms { return "voip.ms" }
        var parts = [deviceName]
        if let carrier = carrier?.trimmingCharacters(in: .whitespaces), !carrier.isEmpty, !carrier.hasPrefix("SIM") { parts.append(carrier) }
        if let slotIndex { parts.append("SIM \(slotIndex + 1)") }
        return parts.joined(separator: " · ")
    }
}

extension AndroidAgentPresentation {
    var isReachable: Bool { cloudOnline || vowlanOnline || bluetoothOnline }
    var isVoipms: Bool { agentKind == "voipms" }
    var routeTitle: String {
        if vowlanOnline { return "局域网" }
        if bluetoothOnline { return "蓝牙" }
        if cloudOnline { return "云端" }
        return "离线"
    }
}

extension AppModel {
    var warmLines: [WarmLine] {
        pairedAndroidAgents.flatMap { agent -> [WarmLine] in
            let slots = simSlots(for: agent.id)
            if slots.isEmpty {
                return [WarmLine(agentID: agent.id, slotID: nil, slotIndex: nil, number: agent.phoneNumber, deviceName: agent.deviceName,
                                 carrier: nil, isVoipms: agent.isVoipms, route: agent.routeTitle, online: agent.isReachable)]
            }
            let now = Date()
            return slots.map {
                WarmLine(agentID: agent.id, slotID: $0.id, slotIndex: $0.slotIndex, number: $0.displayNumber, deviceName: agent.deviceName,
                         carrier: $0.carrierName, isVoipms: agent.isVoipms, route: agent.routeTitle, online: agent.isReachable,
                         signal: $0.signal?.freshLevel(at: now))
            }
        }
    }

    var warmCurrentLine: WarmLine? {
        let lines = warmLines
        guard let agent = currentAndroidAgent else { return lines.first }
        let own = lines.filter { $0.agentID == agent.id }
        let selected = selectedSIMSlotID(for: agent.id)
        return own.first { $0.slotID == selected } ?? own.first
    }

    /// The line a record was carried on (device + slot), if it is still configured.
    func warmLine(agentID: String?, slotIndex: Int?) -> WarmLine? {
        guard let agentID else { return nil }
        let lines = warmLines.filter { $0.agentID == agentID }
        guard let slotIndex else { return lines.count == 1 ? lines.first : nil }
        return lines.first { $0.slotIndex == slotIndex }
    }

    var warmInCall: Bool { callLifecycleSnapshot.state.representsCall || pendingOutgoingCall != nil }

    /// Makes `line` the default for the next call / new message. Never during a call.
    @discardableResult
    func warmSelect(_ line: WarmLine) -> Bool {
        guard !warmInCall else { errorMessage = "通话中不能切换线路"; return false }
        if currentAndroidAgent?.id != line.agentID { bindAndroidAgent(line.agentID) }
        if let slot = line.slotID { selectSIMSlot(slot, for: line.agentID) }
        UISelectionFeedbackGenerator().selectionChanged()
        return true
    }

    /// Calls `number` on `line` (or the default line). The line becomes the default.
    func warmDial(_ number: String, on line: WarmLine? = nil) {
        if let line, line != warmCurrentLine, !warmSelect(line) { return }
        numberInput = number
        Task { await dial() }
    }

    var warmVoicemails: [SMSMessage] {
        messages.filter { $0.attachments?.contains { $0.kind == .audio } == true }.sorted { $0.timestamp > $1.timestamp }
    }

    /// Unread conversations (the 短信 tab badge counts conversations, not messages).
    var warmUnreadConversations: Int {
        Set(messages.filter { unreadMessageIDs.contains($0.id) }.map { SMSConversationKey.key(for: $0.sender) }).count
    }

    func warmSourceLabel(agentID: String?, slot: String?) -> String {
        let trimmed = slot?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "线路未知" }
        let name = SIMLineDisplay.name(agentID: agentID, line: trimmed)
        if !name.hasPrefix("SIM ") { return WarmPhone.format(name) }
        let device = pairedAndroidAgents.first { $0.id == agentID }?.deviceName
        return device.map { "\($0) · \(trimmed)" } ?? trimmed
    }

    /// Compact line tag for list rows ("尾号 0111", "家中 K40 · SIM 1"); nil with a single line,
    /// where naming the line adds nothing. Details and pickers keep the full number.
    func warmLineTag(agentID: String?, slot: String?) -> String? {
        guard warmLines.count > 1 else { return nil }
        let label = warmSourceLabel(agentID: agentID, slot: slot)
        guard label != "线路未知" else { return nil }
        var number: String? = label.hasPrefix("+") || label.first?.isNumber == true ? label : nil
        if number == nil, let slot, slot.hasPrefix("SIM "), let index = Int(slot.dropFirst(4)) {
            number = warmLine(agentID: agentID, slotIndex: index - 1)?.number
        }
        let digits = WarmPhone.digits(number ?? "")
        return digits.count >= 4 ? "尾号 \(digits.suffix(4))" : label
    }
}

/// 未听 is separate from SMS 未读: only a successful playback marks a voicemail heard.
enum WarmHeardVoicemails {
    private static let key = "airsim.warm.heard-voicemails"
    static func all() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func markHeard(_ id: String) {
        var heard = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !heard.contains(id) else { return }
        heard.append(id)
        UserDefaults.standard.set(Array(heard.suffix(500)), forKey: key)
    }
    /// "全部标为已读": an explicit user choice, so it may mark unplayed voicemails heard.
    static func markAllHeard(_ ids: [String]) {
        var heard = UserDefaults.standard.stringArray(forKey: key) ?? []
        let known = Set(heard)
        heard += ids.filter { !known.contains($0) }
        UserDefaults.standard.set(Array(heard.suffix(500)), forKey: key)
    }
}

enum WarmDate {
    /// List time: "09:24", "昨天", "11月18日".
    static func list(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return day(date)
    }
    /// Section title: "今天", "昨天", "11月18日", "2025年11月18日".
    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let year = calendar.component(.year, from: date)
        let md = "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
        return year == calendar.component(.year, from: Date()) ? md : "\(year)年\(md)"
    }
    /// Detail time: "今天 09:24".
    static func full(_ date: Date) -> String { "\(day(date)) \(date.formatted(date: .omitted, time: .shortened))" }
    static func duration(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded())
        return value >= 60 ? "\(value / 60)分\(value % 60)秒" : "\(value)秒"
    }
    static func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

// MARK: - Shared components

struct WarmPageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.title.weight(.bold)).foregroundStyle(Warm.text).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .frame(minHeight: 56)
        .padding(.top, 4)
    }
}

struct WarmIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 20, weight: .regular)).foregroundStyle(Warm.accent)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Small gray group caption ("今天", "线路"), the way system lists label sections.
struct WarmSectionTitle: View {
    let title: String
    var action: (title: String, run: () -> Void)? = nil
    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(Warm.secondary).accessibilityAddTraits(.isHeader)
            Spacer()
            if let action {
                Button(action.title, action: action.run)
                    .font(.footnote)
                    .foregroundStyle(Warm.accent)
                    .frame(minHeight: 32)
            }
        }
        .frame(minHeight: 32, alignment: .bottom)
        .padding(.bottom, 6)
    }
}

/// Four ascending bars like the status bar. Unknown / stale signal draws all bars faint, never "0 bars".
struct WarmSignalBars: View {
    let level: Int?
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(level.map { index < $0 } == true ? Warm.text : Warm.disabled.opacity(0.45))
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }
        .frame(width: 18, height: 13, alignment: .bottomLeading)
        .accessibilityElement()
        .accessibilityLabel(level.map { "信号 \($0) 格" } ?? "信号未知")
    }
}

/// Contact-card style quick action: glyph over a short label, accent on a muted tile.
struct WarmActionTile: View {
    let systemImage: String
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 19, weight: .regular)).frame(height: 22)
                Text(title).font(.caption.weight(.medium))
            }
            .foregroundStyle(isEnabled ? Warm.accent : Warm.disabled)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Warm.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Online dot + route word; state never relies on color alone.
struct WarmRouteLabel: View {
    let route: String
    let online: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(online ? Warm.positive : Warm.disabled).frame(width: 6, height: 6)
            Text(route).font(.caption).foregroundStyle(Warm.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct WarmPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(isEnabled ? Warm.onAccent : Warm.disabled)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(isEnabled ? Warm.accent : Warm.disabledFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.1))
                }
            }
    }
}

struct WarmSearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(Warm.secondary)
            TextField(prompt, text: $text)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Warm.secondary).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除")
            }
        }
        .padding(.leading, 12)
        .frame(minHeight: 44)
        .background(Warm.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct WarmNotice: View {
    let text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 18))
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
        }
        .foregroundStyle(Warm.warningText)
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(Warm.warningSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct WarmEmptyState: View {
    let systemImage: String
    let title: String
    var detail: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: systemImage).font(.system(size: 28, weight: .regular)).foregroundStyle(Warm.secondary)
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Warm.text).padding(.top, 16)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(Warm.secondary).multilineTextAlignment(.center)
                    .lineLimit(3).padding(.top, 6)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(WarmPrimaryButtonStyle()).frame(maxWidth: 220).padding(.top, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 64)
    }
}

// MARK: - Shell

enum WarmTab: CaseIterable {
    case home, calls, messages, account
    var title: String {
        switch self {
        case .home: return "首页"
        case .calls: return "通话"
        case .messages: return "短信"
        case .account: return "我的"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .calls: return "circle.grid.3x3"
        case .messages: return "message"
        case .account: return "person.crop.circle"
        }
    }
}

struct WarmSettingsRoute: Identifiable {
    let id = UUID()
    let path: [AirSIMSettingsPage]
}

enum WarmLineContext: Identifiable {
    case defaultLine, dial
    var id: Self { self }
    var title: String { self == .dial ? "拨号线路" : "默认线路" }
    var detail: String { self == .dial ? "用于本次拨号。" : "用于下一次拨号和新建短信。" }
}

/// Cross-tab actions handed to every page.
struct WarmActions {
    let openTab: (PhoneTab) -> Void
    let openSettings: ([AirSIMSettingsPage]) -> Void
    let pickLine: (WarmLineContext) -> Void
    let compose: (String?) -> Void
    let message: (String) -> Void
}

struct WarmShellView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appUpdates: AppUpdateController
    @Binding var phoneTab: PhoneTab
    @Binding var pendingSMSRecipient: String?
    @Binding var conversationSender: String?
    @Binding var showingConversation: Bool
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    let openConversation: (String) -> Void
    @AppStorage("airsim.warm.calls-segment") private var lastCallsSegment = PhoneTab.dial.rawValue
    @State private var settingsRoute: WarmSettingsRoute?
    @State private var lineContext: WarmLineContext?
    @State private var callsPath: [String] = []
    @State private var tabBarHeight: CGFloat = 50

    private var tab: WarmTab {
        switch phoneTab {
        case .home: return .home
        case .dial, .recents, .contacts, .voicemail: return .calls
        case .messages: return .messages
        case .settings: return .account
        }
    }

    private func select(_ tab: WarmTab) {
        switch tab {
        case .home: phoneTab = .home
        case .calls: phoneTab = PhoneTab(rawValue: lastCallsSegment) ?? .dial
        case .messages: phoneTab = .messages
        case .account: phoneTab = .settings
        }
    }

    private var callsSegment: Binding<PhoneTab> {
        Binding(
            get: { [.dial, .recents, .contacts, .voicemail].contains(phoneTab) ? phoneTab : (PhoneTab(rawValue: lastCallsSegment) ?? .dial) },
            set: { phoneTab = $0; lastCallsSegment = $0.rawValue }
        )
    }

    private var actions: WarmActions {
        WarmActions(
            openTab: { tab in
                phoneTab = tab
                if [.dial, .recents, .contacts, .voicemail].contains(tab) { lastCallsSegment = tab.rawValue }
            },
            openSettings: { settingsRoute = WarmSettingsRoute(path: $0) },
            pickLine: { lineContext = $0 },
            compose: { recipient in pendingSMSRecipient = recipient ?? ""; phoneTab = .messages },
            message: onMessage)
    }

    private var tabBar: some View {
        WarmTabBar(selection: tab, select: select,
                   badges: [.calls: model.unseenMissedCallIDs.count, .messages: model.warmUnreadConversations])
    }

    /// Pushed pages (a conversation, a contact) cover the tab bar.
    private var showsTabBar: Bool {
        !(tab == .messages && showingConversation) && !(tab == .calls && !callsPath.isEmpty)
    }

    var body: some View {
        // TabView keeps each tab's navigation and scroll state and exposes only the selected tab to
        // VoiceOver; its own bar is hidden in favour of the custom one below.
        TabView(selection: Binding(get: { tab }, set: { select($0) })) {
            NavigationStack {
                WarmHomeView(actions: actions).toolbar(.hidden, for: .tabBar).modifier(WarmTabBarSpace(height: tabBarHeight))
            }
            .tag(WarmTab.home)
            WarmCallsView(segment: callsSegment, path: $callsPath, actions: actions, tabBarHeight: tabBarHeight)
                .tag(WarmTab.calls)
            NavigationStack {
                WarmMessagesView(pendingRecipient: $pendingSMSRecipient, open: openConversation)
                    .toolbar(.hidden, for: .tabBar)
                    .modifier(WarmTabBarSpace(height: tabBarHeight))
                    .navigationDestination(isPresented: $showingConversation) {
                        if let sender = conversationSender {
                            MessageThreadView(sender: sender).id(sender).toolbar(.hidden, for: .tabBar)
                        }
                    }
            }
            .tag(WarmTab.messages)
            NavigationStack {
                WarmAccountView(actions: actions).toolbar(.hidden, for: .tabBar).modifier(WarmTabBarSpace(height: tabBarHeight))
            }
            .tag(WarmTab.account)
        }
        .id(settings.theme)
        // One tab bar for the whole shell; each root reserves its height (WarmTabBarSpace).
        // Every root page paints its own background (grouped gray or plain).
        .overlay(alignment: .bottom) {
            if showsTabBar {
                tabBar.background(GeometryReader { proxy in
                    Color.clear.onAppear { tabBarHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { tabBarHeight = $0 }
                })
            }
        }
        .background(Warm.background.ignoresSafeArea())
        .sheet(item: $settingsRoute) { route in
            AirSIMSettingsView(initialPath: route.path, showsDoneButton: true)
                .environmentObject(model)
                .environmentObject(model.contacts)
                .environmentObject(model.audio)
                .environmentObject(settings)
                .environmentObject(appUpdates)
        }
        .sheet(item: $lineContext) { context in
            WarmLinePicker(context: context, addDevice: {
                lineContext = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { settingsRoute = WarmSettingsRoute(path: [.add]) }
            })
            .environmentObject(model)
        }
    }
}

/// Keeps a root page's content clear of the shell's floating tab bar.
struct WarmTabBarSpace: ViewModifier {
    let height: CGFloat
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: height).accessibilityHidden(true)
        }
    }
}

struct WarmTabBar: View {
    let selection: WarmTab
    let select: (WarmTab) -> Void
    let badges: [WarmTab: Int]

    var body: some View {
        VStack(spacing: 0) {
            WarmHairline()
            HStack(spacing: 0) {
                ForEach(WarmTab.allCases, id: \.self) { item in
                    let selected = item == selection
                    let count = badges[item] ?? 0
                    Button { select(item) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: selected ? item.icon + ".fill" : item.icon)
                                .font(.system(size: 21, weight: selected ? .semibold : .regular))
                                .frame(height: 26)
                                .overlay(alignment: .topTrailing) {
                                    if count > 0 {
                                        Text(count > 99 ? "99+" : "\(count)")
                                            .font(.system(size: 10, weight: .semibold))
                                            .monospacedDigit()
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 4)
                                            .frame(minWidth: 16, minHeight: 16)
                                            .background(Warm.danger, in: Capsule())
                                            .offset(x: 11, y: -4)
                                    }
                                }
                            Text(item.title).font(.caption2.weight(selected ? .semibold : .medium))
                        }
                        .foregroundStyle(selected ? Warm.accent : Warm.secondary)
                        .frame(maxWidth: .infinity, minHeight: 49)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(count > 0 ? "\(item.title)，\(count) 个未读" : item.title)
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
        .background(Warm.plain.ignoresSafeArea(edges: .bottom))
    }
}

// MARK: - Line picker (P14)

struct WarmLinePicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let context: WarmLineContext
    let addDevice: () -> Void

    var body: some View {
        let lines = model.warmLines
        let current = model.warmCurrentLine
        let groups = Dictionary(grouping: lines, by: \.agentID)
        let order = model.pairedAndroidAgents.map(\.id).filter { groups[$0] != nil }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(context.detail).font(.subheadline).foregroundStyle(Warm.secondary).padding(.bottom, 12)
                    if model.warmInCall {
                        WarmNotice(text: "通话中不能切换线路").padding(.bottom, 12)
                    }
                    if lines.isEmpty {
                        Text("还没有线路").font(.body).foregroundStyle(Warm.secondary).padding(.vertical, 12)
                    }
                    ForEach(order, id: \.self) { agentID in
                        if let group = groups[agentID], let first = group.first {
                            HStack {
                                Text(first.deviceName).font(.subheadline.weight(.semibold)).foregroundStyle(Warm.text)
                                Spacer()
                                WarmRouteLabel(route: first.route, online: first.online)
                            }
                            .frame(minHeight: 32)
                            .padding(.top, 12)
                            ForEach(group) { line in
                                row(line, selected: line == current)
                                WarmHairline()
                            }
                        }
                    }
                    Button(action: addDevice) {
                        Label("添加设备", systemImage: "plus").font(.body).foregroundStyle(Warm.accent)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Warm.surface.ignoresSafeArea())
            .navigationTitle(context.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .tint(Warm.accent)
        .presentationDetents(lines.count > 3 ? [.large] : [.medium, .large])
    }

    private func row(_ line: WarmLine, selected: Bool) -> some View {
        let blockedOffline = context == .dial && !line.online
        let disabled = model.warmInCall || blockedOffline
        return Button {
            if model.warmSelect(line) { dismiss() }
        } label: {
            HStack(spacing: 14) {
                WarmSignalBars(level: line.online ? line.signal : nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.title).font(selected ? .body.weight(.semibold) : .body).monospacedDigit()
                        .foregroundStyle(disabled ? Warm.disabled : Warm.text)
                    Text(line.source).font(.subheadline).foregroundStyle(Warm.secondary)
                    if blockedOffline {
                        Text("设备离线，暂时无法拨号或发送短信").font(.caption).foregroundStyle(Warm.warningText)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Warm.accent)
                }
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Home (P01, P15)

/// Home is the line board: every line with its signal and the default checkmark, then the devices.
/// Calling and texting live in their tabs; missed / unread counts live on the tab badges.
struct WarmHomeView: View {
    @EnvironmentObject private var model: AppModel
    let actions: WarmActions

    var body: some View {
        let agents = model.pairedAndroidAgents
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WarmPageHeader(title: "AirSIM") { EmptyView() }
                if agents.isEmpty {
                    WarmEmptyState(systemImage: "simcard", title: "还没有线路",
                                   detail: "添加安卓手机或 voip.ms 号码，在这台 iPhone 上打电话、收短信。",
                                   actionTitle: "添加设备") { actions.openSettings([.add]) }
                } else {
                    content.padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 16)
        }
        .background(Warm.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var content: some View {
        let lines = model.warmLines
        let current = model.warmCurrentLine
        let agents = model.pairedAndroidAgents
        VStack(alignment: .leading, spacing: 0) {
            WarmSectionTitle(title: "线路").padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    lineRow(line, isDefault: line == current)
                    if index < lines.count - 1 { WarmHairline().padding(.leading, 48) }
                }
            }
            .warmCard()
            Text(model.warmInCall ? "通话中不能切换默认线路。" : "打勾的是默认线路，用于拨号和新建短信。")
                .font(.footnote).foregroundStyle(Warm.secondary)
                .padding(.horizontal, 4).padding(.top, 8)

            WarmSectionTitle(title: "设备").padding(.horizontal, 4).padding(.top, 24)
            VStack(spacing: 0) {
                ForEach(agents) { agent in
                    Button { actions.openSettings([.connections, .device(agent.id)]) } label: { deviceRow(agent) }
                        .buttonStyle(.plain)
                    WarmHairline().padding(.leading, 16)
                }
                Button { actions.openSettings([.add]) } label: {
                    Text("添加设备").font(.body).foregroundStyle(Warm.accent)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .warmCard()
        }
    }

    private func lineRow(_ line: WarmLine, isDefault: Bool) -> some View {
        Button { model.warmSelect(line) } label: {
            HStack(spacing: 14) {
                WarmSignalBars(level: line.online ? line.signal : nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.title)
                        .font(isDefault ? .body.weight(.semibold) : .body)
                        .monospacedDigit()
                        .foregroundStyle(Warm.text)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 0) {
                        Text(line.source).foregroundStyle(Warm.secondary)
                        if !line.online { Text(" · 离线").foregroundStyle(Warm.warningText) }
                    }
                    .font(.subheadline)
                    .lineLimit(2)
                }
                Spacer(minLength: 8)
                if isDefault {
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(Warm.accent)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(line.title)，\(line.source)\(line.online ? "" : "，离线")")
        .accessibilityAddTraits(isDefault ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(isDefault ? "" : "设为默认线路")
        .contextMenu {
            if let number = line.number {
                Button { UIPasteboard.general.string = number } label: { Label("复制号码", systemImage: "doc.on.doc") }
            }
            if !isDefault {
                Button { model.warmSelect(line) } label: { Label("设为默认线路", systemImage: "checkmark") }
            }
        }
    }

    private func deviceRow(_ agent: AndroidAgentPresentation) -> some View {
        let battery = agent.isVoipms ? nil : model.androidBattery(for: agent.id)
        return HStack(alignment: .center, spacing: 12) {
            Text(agent.deviceName).font(.body).foregroundStyle(Warm.text).lineLimit(1)
            Spacer(minLength: 8)
            if agent.isReachable {
                Text([agent.routeTitle, battery.map { "电量 \($0.percent)%" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).monospacedDigit().foregroundStyle(Warm.secondary).lineLimit(1)
            } else {
                Text("离线").font(.subheadline).foregroundStyle(Warm.warningText)
            }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Warm.disabled)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

// MARK: - Calls (P02–P06, P16–P18, P21–P23)

struct WarmCallsView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var segment: PhoneTab
    @Binding var path: [String]
    let actions: WarmActions
    let tabBarHeight: CGFloat
    @State private var tick = 0
    @State private var confirmingVoicemailClear = false

    private var unheardVoicemails: Int {
        _ = tick
        let heard = WarmHeardVoicemails.all()
        return model.warmVoicemails.filter { !heard.contains($0.id) }.count
    }

    /// Clears the 通话 badge (missed calls) and the 语音信箱 count (unheard voicemails) in one go.
    private func markAllRead() {
        model.markMissedCallsSeen()
        WarmHeardVoicemails.markAllHeard(model.warmVoicemails.map(\.id))
        NotificationCenter.default.post(name: SMSAudioPlayback.didChange, object: nil)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                WarmPageHeader(title: "通话") {
                    Menu {
                        Button { markAllRead() } label: { Label("全部标为已读", systemImage: "checkmark.circle") }
                            .disabled(model.unseenMissedCallIDs.isEmpty && unheardVoicemails == 0)
                        if segment == .voicemail, !model.warmVoicemails.isEmpty {
                            Button(role: .destructive) { confirmingVoicemailClear = true } label: {
                                Label("清空全部语音留言", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 20)).foregroundStyle(Warm.accent).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("更多操作")
                }
                WarmSegmentedControl(selection: $segment, items: [
                    .init(tab: .dial, title: "拨号"),
                    .init(tab: .recents, title: "最近", count: model.unseenMissedCallIDs.count),
                    .init(tab: .contacts, title: "联系人"),
                    .init(tab: .voicemail, title: "语音信箱", count: unheardVoicemails),
                ])
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                Group {
                    switch segment {
                    case .recents: WarmRecentsList(actions: actions, showVoicemail: { segment = .voicemail })
                    case .contacts: WarmContactsList(actions: actions, path: $path)
                    case .voicemail: WarmVoicemailList(actions: actions)
                    default: WarmKeypad(actions: actions)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Warm.plain.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .modifier(WarmTabBarSpace(height: tabBarHeight))
            .navigationDestination(for: String.self) { contactID in
                WarmContactDetail(contactID: contactID, actions: actions) { number in
                    path = []
                    model.numberInput = number
                    segment = .dial
                }
                .toolbar(.hidden, for: .tabBar)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SMSAudioPlayback.didChange)) { _ in tick &+= 1 }
        .confirmationDialog("清空全部语音留言？", isPresented: $confirmingVoicemailClear, titleVisibility: .visible) {
            let ids = Set(model.warmVoicemails.map(\.id))
            Button("清空 \(ids.count) 条", role: .destructive) {
                SMSAudioPlayback.shared.stop()
                model.deleteMessages(ids: ids)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除此 iPhone 上 AirSIM 内的留言记录，并从短信会话中移除对应留言。此操作无法撤销。")
        }
    }
}

struct WarmSegmentedControl: View {
    struct Item { let tab: PhoneTab; let title: String; var count: Int = 0 }
    @Binding var selection: PhoneTab
    let items: [Item]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // From XXXL on, four equal segments would truncate: scroll a row of full-size labels instead.
        if typeSize >= .xxxLarge {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(items, id: \.tab) { item in segment(item).fixedSize().id(item.tab) }
                    }
                    .padding(3)
                }
                .background(Warm.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onAppear { reader.scrollTo(selection) }
                .onChange(of: selection) { reader.scrollTo($0) }
            }
        } else {
            HStack(spacing: 0) {
                ForEach(items, id: \.tab) { item in segment(item) }
            }
            .padding(3)
            .background(Warm.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func segment(_ item: Item) -> some View {
        let selected = selection == item.tab
        return Button {
            withAnimation(.easeOut(duration: 0.12)) { selection = item.tab }
        } label: {
            HStack(spacing: 4) {
                Text(item.title).font(.subheadline.weight(selected ? .semibold : .medium)).lineLimit(1)
                if item.count > 0 {
                    Text(item.count > 9 ? "9+" : "\(item.count)")
                        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Warm.danger)
                }
            }
            .foregroundStyle(selected ? Warm.text : Warm.secondary)
            .padding(.horizontal, typeSize >= .xxxLarge ? 14 : 0)
            .frame(maxWidth: typeSize >= .xxxLarge ? nil : .infinity, minHeight: typeSize >= .xxxLarge ? 44 : 32)
            .background(selected ? Warm.raised : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.count > 0 ? "\(item.title)，\(item.count)" : item.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: Keypad (P02, P17, P18)

private struct WarmKeyStyle: ButtonStyle {
    let digit: String
    let tones: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed { Circle().fill(Warm.muted).frame(width: 64, height: 64) }
            }
            .onChange(of: configuration.isPressed) { pressed in
                if pressed && tones { LocalDialTone.shared.start(digit) } else { LocalDialTone.shared.stop(respectingMinimum: true) }
            }
            .onDisappear { LocalDialTone.shared.stop() }
    }
}

struct WarmKeypad: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let actions: WarmActions
    @State private var zeroWasLongPressed = false
    @State private var deleteRepeatTask: Task<Void, Never>?

    private let rows = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]

    var body: some View {
        let line = model.warmCurrentLine
        let lineOffline = line.map { !$0.online } ?? true
        let canCall = !model.numberInput.isEmpty && !model.isBusy && model.canStartOutgoingCommand && !lineOffline && !model.warmInCall
        GeometryReader { proxy in
            let keyHeight = max(56, min(72, (proxy.size.height - 268) / 4))
            ScrollView {
                VStack(spacing: 0) {
                    if model.warmInCall {
                        WarmNotice(text: "通话中，暂不能再次拨号。", actionTitle: "返回通话") { model.presentCurrentCallInApp() }
                            .padding(.horizontal, 20)
                    } else if let line, !line.online {
                        WarmNotice(text: "\(line.deviceName) 已离线。", actionTitle: "选择其他线路") { actions.pickLine(.dial) }
                            .padding(.horizontal, 20)
                    }
                    Spacer(minLength: 8).frame(maxHeight: 40)
                    numberDisplay
                    Text(contacts.contact(for: model.numberInput)?.name ?? " ")
                        .font(.subheadline).foregroundStyle(Warm.secondary).padding(.top, 2)
                    lineRow(line).padding(.top, 8)
                    Spacer(minLength: 4).frame(maxHeight: 24)
                    VStack(spacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 12) {
                                ForEach(row, id: \.0) { digit, letters in key(digit, letters, height: keyHeight) }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    HStack(spacing: 12) {
                        Color.clear.frame(maxWidth: .infinity, minHeight: 64)
                        Button { Task { await model.dial() } } label: {
                            Circle()
                                .fill(canCall ? Warm.call : Warm.disabledFill)
                                .frame(width: 68, height: 68)
                                .overlay(Image(systemName: "phone.fill").font(.system(size: 28))
                                    .foregroundStyle(canCall ? Color.white : Warm.disabled))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canCall)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("拨打")
                        .accessibilityHint(model.numberInput.isEmpty ? "输入号码后拨打" : "")
                        deleteKey.frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                }
                .frame(minHeight: proxy.size.height)
            }
        }
        .onDisappear { deleteRepeatTask?.cancel(); deleteRepeatTask = nil }
    }

    private var numberDisplay: some View {
        // Empty until the first digit, like the system keypad; the line row below says where it dials from.
        Text(model.numberInput.isEmpty ? " " : model.numberInput)
            .font(.largeTitle.weight(.regular))
            .monospacedDigit()
            .foregroundStyle(Warm.text)
            .accessibilityLabel(model.numberInput.isEmpty ? "号码，未输入" : model.numberInput)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 24)
            .frame(minHeight: 44)
            .contextMenu {
                Button { UIPasteboard.general.string = model.numberInput } label: { Label("复制", systemImage: "doc.on.doc") }
                    .disabled(model.numberInput.isEmpty)
                Button {
                    if let raw = UIPasteboard.general.string { model.numberInput = DialPadPasteSanitizer.sanitize(raw) }
                } label: { Label("粘贴", systemImage: "doc.on.clipboard") }
            }
            .accessibilityIdentifier("warm.dial.number")
    }

    private func lineRow(_ line: WarmLine?) -> some View {
        Button { actions.pickLine(.dial) } label: {
            HStack(spacing: 6) {
                Text(line.map { "从 \($0.title) 拨出" } ?? "选择拨号线路")
                    .font(.subheadline).monospacedDigit().foregroundStyle(Warm.secondary).lineLimit(1).minimumScaleFactor(0.85)
                Image(systemName: model.warmInCall ? "lock" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Warm.secondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("warm.dial.line")
    }

    private func key(_ digit: String, _ letters: String, height: CGFloat) -> some View {
        Button {
            guard !(digit == "0" && zeroWasLongPressed) else { zeroWasLongPressed = false; return }
            model.numberInput.append(digit)
        } label: {
            VStack(spacing: 0) {
                Text(digit).font(.largeTitle.weight(.regular)).foregroundStyle(Warm.text)
                Text(letters.isEmpty ? " " : letters).font(.caption2.weight(.medium)).tracking(1.2).foregroundStyle(Warm.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(WarmKeyStyle(digit: digit, tones: !model.isMuted && !model.warmInCall))
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            if digit == "0" { zeroWasLongPressed = true; model.numberInput.append("+") }
        })
        .accessibilityLabel(letters.isEmpty ? digit : "\(digit) \(letters)")
    }

    private var deleteKey: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 22))
            .foregroundStyle(Warm.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .opacity(model.numberInput.isEmpty ? 0 : 1)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in beginDeleting() }
                .onEnded { _ in deleteRepeatTask?.cancel(); deleteRepeatTask = nil })
            .allowsHitTesting(!model.numberInput.isEmpty)
            .accessibilityHidden(model.numberInput.isEmpty)
            .accessibilityLabel("删除一位")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { deleteLast() }
            .accessibilityAction(named: "清除号码") { model.numberInput = "" }
    }

    private func deleteLast() {
        guard !model.numberInput.isEmpty else { return }
        model.numberInput = DialPadDeletePolicy.removingLast(from: model.numberInput)
    }

    private func beginDeleting() {
        guard deleteRepeatTask == nil, !model.numberInput.isEmpty else { return }
        deleteLast()
        deleteRepeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            while !Task.isCancelled, !model.numberInput.isEmpty {
                deleteLast()
                try? await Task.sleep(for: .milliseconds(90))
            }
            deleteRepeatTask = nil
        }
    }
}

// MARK: Recents (P03, P23)

struct WarmRecentsList: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let actions: WarmActions
    let showVoicemail: () -> Void
    @State private var missedOnly = false
    @State private var detail: CallRecord?
    @State private var visible = false

    private func markSeenIfShown() {
        guard visible, scenePhase == .active, !model.callHistory.isEmpty else { return }
        model.markMissedCallsSeen()
    }

    var body: some View {
        let records = model.callHistory.filter { !missedOnly || ($0.direction == "incoming" && $0.missed) }
        let sections = Dictionary(grouping: records) { Calendar.current.startOfDay(for: $0.startedAt) }
            .sorted { $0.key > $1.key }
        let missedCount = model.callHistory.filter { $0.direction == "incoming" && $0.missed }.count
        // A plain List (not a ScrollView) so rows get the system swipe-to-delete.
        List {
            HStack(spacing: 18) {
                filter("全部", selected: !missedOnly) { missedOnly = false }
                filter(missedCount > 0 ? "未接 \(missedCount)" : "未接", selected: missedOnly) { missedOnly = true }
                Spacer()
            }
            .padding(.top, 2)
            .warmListRow()
            if records.isEmpty {
                Group {
                    if missedOnly {
                        WarmEmptyState(systemImage: "phone", title: "没有未接来电")
                    } else {
                        WarmEmptyState(systemImage: "phone", title: "暂无通话记录", detail: "拨打或接听的电话会显示在这里。",
                                       actionTitle: "去拨号") { actions.openTab(.dial) }
                    }
                }
                .warmListRow()
            }
            ForEach(sections, id: \.key) { day, calls in
                WarmSectionTitle(title: WarmDate.day(day)).padding(.top, 8).warmListRow()
                let sorted = calls.sorted { $0.startedAt > $1.startedAt }
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, call in
                    WarmRecentRow(call: call, hasVoicemail: hasVoicemail(call)) { detail = call }
                        .warmListRow(separator: index < sorted.count - 1)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { model.deleteCallHistory(ids: [call.id]) } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .tint(Warm.danger)
                        }
                }
            }
            Color.clear.frame(height: 16).warmListRow()
        }
        .warmPlainList()
        .refreshable { await model.refreshCallHistory() }
        // Missed calls count as seen while this list is on screen — including records that
        // arrive after it appeared (cloud lines sync a few seconds later) or while the app was
        // in the background with the list open. Marking only on appear left the tab badge stale.
        .onAppear { visible = true; markSeenIfShown() }
        .onDisappear { visible = false }
        .onChange(of: model.callHistory) { _ in markSeenIfShown() }
        .onChange(of: scenePhase) { _ in markSeenIfShown() }
        .sheet(item: $detail) { call in
            WarmCallDetail(call: call, hasVoicemail: hasVoicemail(call), actions: actions) {
                detail = nil
                showVoicemail()
            }
            .environmentObject(model)
            .environmentObject(model.contacts)
        }
    }

    private func filter(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Warm.text : Warm.secondary)
                .frame(minHeight: 40)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func hasVoicemail(_ call: CallRecord) -> Bool {
        guard call.missed, let number = call.number else { return false }
        return model.warmVoicemails.contains {
            SMSConversationKey.same($0.sender, number) && abs($0.timestamp.timeIntervalSince(call.startedAt)) < 300
        }
    }
}

private struct WarmRecentRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let call: CallRecord
    let hasVoicemail: Bool
    let open: () -> Void

    private var incoming: Bool { call.direction == "incoming" }

    var body: some View {
        // Two lines: who (red when missed, like the system Phone app), then what happened and on which line.
        let tag = model.warmLineTag(agentID: call.sourceAgentID, slot: call.slotIndex.map { "SIM \($0 + 1)" })
        let what = call.missed
            ? (hasVoicemail ? "未接 · 有留言" : "未接")
            : (incoming ? "呼入" : "呼出") + (call.connectedDuration.map { " " + WarmDate.duration($0) } ?? "")
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(WarmPhone.name(call.number, contacts: contacts))
                        .font(.body.weight(.medium)).monospacedDigit()
                        .foregroundStyle(call.missed ? Warm.danger : Warm.text)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Image(systemName: incoming ? "phone.arrow.down.left" : "phone.arrow.up.right")
                            .font(.system(size: 11, weight: .medium))
                        Text([what, tag].compactMap { $0 }.joined(separator: " · ")).monospacedDigit()
                    }
                    .font(.subheadline)
                    .foregroundStyle(Warm.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                // Rows sit under a day heading, so they carry only the time.
                Text(call.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline).monospacedDigit().foregroundStyle(Warm.secondary)
            }
            .padding(.vertical, 9)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看通话详情")
        .contextMenu {
            if let number = call.number {
                Button { UIPasteboard.general.string = number } label: { Label("复制", systemImage: "doc.on.doc") }
            }
            Button(role: .destructive) { model.deleteCallHistory(ids: [call.id]) } label: { Label("删除", systemImage: "trash") }
        }
    }
}

private struct WarmCallDetail: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    @Environment(\.dismiss) private var dismiss
    let call: CallRecord
    let hasVoicemail: Bool
    let actions: WarmActions
    let playVoicemail: () -> Void

    var body: some View {
        let line = model.warmLine(agentID: call.sourceAgentID, slotIndex: call.slotIndex)
        let incoming = call.direction == "incoming"
        let name = contacts.contact(for: call.number ?? "")?.name
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(name ?? WarmPhone.format(call.number)).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(Warm.text)
                    if name != nil, let number = call.number {
                        Text(WarmPhone.format(number)).font(.body).monospacedDigit().foregroundStyle(Warm.secondary).padding(.top, 4)
                            .textSelection(.enabled)
                    }
                    if let number = RecentCallDialPolicy.numberToDial(call.number) {
                        HStack(spacing: 8) {
                            WarmActionTile(systemImage: "phone.fill", title: "回拨") {
                                dismiss()
                                model.warmDial(number, on: line?.online == true ? line : nil)
                            }
                            .disabled(model.warmInCall)
                            WarmActionTile(systemImage: "message.fill", title: "短信") { dismiss(); actions.message(number) }
                            if hasVoicemail {
                                WarmActionTile(systemImage: "recordingtape", title: "留言", action: playVoicemail)
                            }
                        }
                        .padding(.top, 20)
                    }
                    if model.warmInCall {
                        WarmNotice(text: "通话中，暂不能再次拨号。").padding(.top, 12)
                    }
                    VStack(spacing: 0) {
                        fact("时间", WarmDate.full(call.startedAt))
                        WarmHairline()
                        fact("通话状态", call.missed ? "未接" : incoming ? "呼入" : "呼出", danger: call.missed)
                        WarmHairline()
                        if let region = PhoneRegionLookup.region(for: call.number) {
                            fact("归属地", region)
                            WarmHairline()
                        }
                        fact("经由线路", model.warmSourceLabel(agentID: call.sourceAgentID, slot: call.slotIndex.map { "SIM \($0 + 1)" }),
                             detail: line.map { "\($0.source) · \($0.route)" })
                        if let duration = call.connectedDuration {
                            WarmHairline()
                            fact("时长", WarmDate.duration(duration))
                        }
                    }
                    .padding(.top, 16)
                }
                .padding(20)
            }
            .background(Warm.surface.ignoresSafeArea())
            .navigationTitle("通话详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onAppear { model.markMissedCallsSeen([call]) }
        }
        .tint(Warm.accent)
        .presentationDetents([.medium, .large])
    }

    private func fact(_ label: String, _ value: String, detail: String? = nil, danger: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(Warm.secondary)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).font(.body).monospacedDigit().foregroundStyle(danger ? Warm.danger : Warm.text).multilineTextAlignment(.trailing)
                if let detail { Text(detail).font(.caption).foregroundStyle(Warm.secondary) }
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 4)
    }
}

// MARK: Contacts (P04, P05, P16)

enum WarmContactSections {
    static func key(_ name: String) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? name
        guard let first = latin.trimmingCharacters(in: .whitespaces).first.map({ String($0).uppercased() }),
              first.count == 1, ("A"..."Z").contains(first) else { return "#" }
        return first
    }
}

struct WarmContactsList: View {
    @EnvironmentObject private var contacts: ContactStore
    @Environment(\.openURL) private var openURL
    let actions: WarmActions
    @Binding var path: [String]
    @State private var search = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !contacts.isAuthorized {
                    unauthorized
                } else {
                    WarmSearchField(prompt: "搜索联系人", text: $search).padding(.bottom, 8)
                    list
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .task { await contacts.loadIfAuthorized() }
    }

    @ViewBuilder
    private var list: some View {
        let query = search.trimmingCharacters(in: .whitespaces)
        let queryDigits = WarmPhone.digits(query)
        let all = contacts.contacts.filter { !$0.phones.isEmpty }
        let filtered = query.isEmpty ? all : all.filter { contact in
            contact.name.localizedCaseInsensitiveContains(query)
                || (!queryDigits.isEmpty && contact.phones.contains { WarmPhone.digits($0).contains(queryDigits) })
        }
        let grouped = Dictionary(grouping: filtered) { WarmContactSections.key($0.name) }
        let keys = grouped.keys.sorted { $0 == "#" ? false : ($1 == "#" ? true : $0 < $1) }
        if all.isEmpty {
            WarmEmptyState(systemImage: "person.2", title: "暂无联系人", detail: "添加到系统通讯录的联系人会显示在这里。")
        } else if filtered.isEmpty {
            WarmEmptyState(systemImage: "magnifyingglass", title: "未找到联系人", detail: "试试姓名或号码。")
        }
        ForEach(keys, id: \.self) { key in
            Text(key).font(.caption.weight(.semibold)).foregroundStyle(Warm.secondary).frame(minHeight: 28, alignment: .bottom)
            let group = (grouped[key] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            ForEach(Array(group.enumerated()), id: \.element.id) { index, contact in
                Button { path.append(contact.id) } label: {
                    HStack(spacing: 12) {
                        Text(contact.name).font(.body).foregroundStyle(Warm.text).lineLimit(2)
                        Spacer(minLength: 8)
                        Text(contact.phones.count > 1 ? "\(contact.phones.count) 个号码" : WarmPhone.format(contact.phones.first))
                            .font(.subheadline).monospacedDigit().foregroundStyle(Warm.secondary).lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Warm.disabled)
                    }
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < group.count - 1 { WarmHairline() }
            }
        }
    }

    private var unauthorized: some View {
        let denied = contacts.authorizationState == .denied
        return VStack(spacing: 0) {
            WarmEmptyState(systemImage: "person.crop.circle",
                           title: denied ? "无法访问通讯录" : "访问通讯录",
                           detail: denied ? "可在系统设置中允许 AirSIM 访问通讯录，或直接输入号码。" : "允许访问后，可按姓名查找联系人。",
                           actionTitle: denied ? "前往设置" : "允许访问通讯录") {
                if denied {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } else {
                    Task { await contacts.requestAccessAndLoad() }
                }
            }
            Button("直接拨号") { actions.openTab(.dial) }
                .font(.callout.weight(.semibold)).foregroundStyle(Warm.accent).frame(minHeight: 44).padding(.top, 8)
        }
    }
}

private struct WarmContactDetail: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let contactID: String
    let actions: WarmActions
    let dial: (String) -> Void

    var body: some View {
        ScrollView {
            if let contact = contacts.contacts.first(where: { $0.id == contactID }) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(contact.name).font(.title.weight(.bold)).foregroundStyle(Warm.text).padding(.top, 24)
                    if contact.phones.isEmpty {
                        Text("这个联系人没有电话号码").font(.subheadline).foregroundStyle(Warm.secondary).padding(.top, 4)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(contact.phones.enumerated()), id: \.offset) { index, number in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.phones.count > 1 ? "号码 \(index + 1)" : "电话").font(.caption).foregroundStyle(Warm.secondary)
                                    Text(WarmPhone.format(number)).font(.body).monospacedDigit().foregroundStyle(Warm.text).textSelection(.enabled)
                                }
                                Spacer(minLength: 8)
                                roundAction("message.fill", "给 \(WarmPhone.format(number)) 发短信") { actions.message(number) }
                                roundAction("phone.fill", "拨打 \(WarmPhone.format(number))") { dial(number) }
                                    .disabled(model.warmInCall)
                            }
                            .frame(minHeight: 64)
                            if index < contact.phones.count - 1 { WarmHairline() }
                        }
                    }
                    .padding(.top, 16)
                    WarmHairline().padding(.top, 8)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("默认线路").font(.caption).foregroundStyle(Warm.secondary)
                            Text(model.warmCurrentLine?.title ?? "未选择").font(.body).monospacedDigit().foregroundStyle(Warm.text)
                        }
                        Spacer()
                        Button("更改") { actions.pickLine(.defaultLine) }.font(.callout.weight(.semibold)).foregroundStyle(Warm.accent)
                            .frame(minHeight: 44)
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 20)
            } else {
                WarmEmptyState(systemImage: "person.crop.circle.badge.questionmark", title: "联系人不可用")
            }
        }
        .background(Warm.plain.ignoresSafeArea())
        .navigationTitle("联系人详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .tint(Warm.accent)
    }

    private func roundAction(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 16))
                .foregroundStyle(Warm.accent)
                .frame(width: 40, height: 40)
                .background(Warm.muted, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: Voicemail (P06, P21, P22)

struct WarmVoicemailList: View {
    @EnvironmentObject private var model: AppModel
    let actions: WarmActions
    @State private var expanded: String?
    @State private var tick = 0

    var body: some View {
        let voicemails = model.warmVoicemails
        let hasVoipms = model.pairedAndroidAgents.contains { $0.isVoipms }
        let sections = Dictionary(grouping: voicemails) { Calendar.current.startOfDay(for: $0.timestamp) }.sorted { $0.key > $1.key }
        List {
            if voicemails.isEmpty {
                Group {
                    if hasVoipms {
                        WarmEmptyState(systemImage: "recordingtape", title: "暂无语音留言", detail: "收到的语音留言会显示在这里。")
                    } else {
                        WarmEmptyState(systemImage: "recordingtape", title: "需要 voip.ms 线路", detail: "语音信箱仅适用于 voip.ms 号码。",
                                       actionTitle: "添加设备") { actions.openSettings([.add]) }
                    }
                }
                .warmListRow()
            }
            ForEach(sections, id: \.key) { day, items in
                WarmSectionTitle(title: WarmDate.day(day)).padding(.top, 8).warmListRow()
                ForEach(Array(items.enumerated()), id: \.element.id) { index, message in
                    WarmVoicemailRow(message: message, expanded: expanded == message.id, tick: tick, actions: actions) {
                        expanded = message.id
                    }
                    .warmListRow(separator: index < items.count - 1)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            if SMSAudioPlayback.shared.isPlaying(message.id) { SMSAudioPlayback.shared.stop() }
                            model.deleteMessages(ids: [message.id])
                        } label: { Label("删除", systemImage: "trash") }
                        .tint(Warm.danger)
                    }
                }
            }
            Color.clear.frame(height: 16).warmListRow()
        }
        .warmPlainList()
        .onReceive(NotificationCenter.default.publisher(for: SMSAudioPlayback.didChange)) { _ in tick &+= 1 }
    }
}

private struct WarmVoicemailRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let message: SMSMessage
    let expanded: Bool
    let tick: Int
    let actions: WarmActions
    let expand: () -> Void
    @State private var loading = false

    private var audio: SMSAttachment? { message.attachments?.first { $0.kind == .audio } }
    private var playing: Bool { _ = tick; return SMSAudioPlayback.shared.isPlaying(message.id) }
    private var heard: Bool { _ = tick; return WarmHeardVoicemails.all().contains(message.id) }
    private var slotIndex: Int? {
        guard let slot = message.simSlot, slot.hasPrefix("SIM "), let index = Int(slot.dropFirst(4)) else { return nil }
        return index - 1
    }

    var body: some View {
        let tag = model.warmLineTag(agentID: message.sourceAgentID, slot: message.simSlot)
        let meta = [audio?.duration.map { WarmDate.clock($0) }, tag].compactMap { $0 }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Circle().fill(heard ? Color.clear : Warm.accent).frame(width: 8, height: 8)
                    .accessibilityLabel(heard ? "" : "未听")
                VStack(alignment: .leading, spacing: 2) {
                    Text(WarmPhone.name(message.sender, contacts: contacts))
                        .font(heard ? .body : .body.weight(.semibold)).monospacedDigit().foregroundStyle(Warm.text)
                        .lineLimit(1)
                    if !meta.isEmpty {
                        Text(meta).font(.subheadline).monospacedDigit().foregroundStyle(Warm.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline).monospacedDigit().foregroundStyle(Warm.secondary)
                Button(action: toggle) {
                    Group {
                        if loading {
                            ProgressView().tint(Warm.accent)
                        } else {
                            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 17))
                                .foregroundStyle(Warm.accent)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? "暂停语音留言" : "播放语音留言")
            }
            if expanded {
                VStack(spacing: 4) {
                    ProgressView(value: playing ? SMSAudioPlayback.shared.progress : 0).tint(Warm.accent)
                    HStack {
                        Text(WarmDate.clock(playing ? SMSAudioPlayback.shared.currentTime : 0))
                        Spacer()
                        Text(WarmDate.clock(audio?.duration ?? SMSAudioPlayback.shared.duration))
                    }
                    .font(.caption).monospacedDigit().foregroundStyle(Warm.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("进度 \(WarmDate.clock(playing ? SMSAudioPlayback.shared.currentTime : 0))，共 \(WarmDate.clock(audio?.duration ?? 0))")
                .padding(.leading, 18).padding(.trailing, 4).padding(.top, 6)
                if let number = RecentCallDialPolicy.numberToDial(message.sender) {
                    HStack(spacing: 24) {
                        Button { model.warmDial(number, on: model.warmLine(agentID: message.sourceAgentID, slotIndex: slotIndex)) } label: {
                            Label("回拨", systemImage: "phone")
                        }
                        .disabled(model.warmInCall)
                        Button { actions.message(number) } label: { Label("发短信", systemImage: "message") }
                        Spacer()
                    }
                    // Inside a List row, default-style buttons would all fire on any tap.
                    .buttonStyle(.borderless)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Warm.accent)
                    .frame(minHeight: 44)
                    .padding(.leading, 18)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if !expanded { expand() } }
        .contextMenu {
            Button(role: .destructive) { model.deleteMessages(ids: [message.id]) } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func toggle() {
        expand()
        guard let audio else { return }
        if playing { SMSAudioPlayback.shared.stop(); return }
        if model.warmInCall { model.errorMessage = "通话中无法播放留言"; return }
        loading = true
        Task { @MainActor in
            defer { loading = false }
            guard let file = try? await SMSMediaStore.shared.file(for: audio) else {
                model.errorMessage = "语音留言下载失败，请检查网络"
                return
            }
            SMSAudioPlayback.shared.toggle(key: message.id, file: file)
            if SMSAudioPlayback.shared.isPlaying(message.id) {
                WarmHeardVoicemails.markHeard(message.id)
                NotificationCenter.default.post(name: SMSAudioPlayback.didChange, object: nil)
            }
        }
    }
}

// MARK: - Messages (P07)

struct WarmMessagesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    @Binding var pendingRecipient: String?
    let open: (String) -> Void
    @State private var search = ""
    @State private var showingComposer = false
    @State private var confirmingClear = false

    private var conversations: [(sender: String, messages: [SMSMessage])] {
        Dictionary(grouping: model.messages) { SMSConversationKey.key(for: $0.sender) }
            .map { _, group in
                let sorted = group.sorted { $0.timestamp < $1.timestamp }
                return (sorted.last { !$0.isOutgoing }?.sender ?? sorted.last?.sender ?? "", sorted)
            }
            .filter { sender, messages in
                PhoneContentSearch.smsMatches(sender: sender, contactName: contacts.contact(for: sender)?.name,
                                              messages: messages, query: search)
            }
            .sorted { ($0.messages.last?.timestamp ?? .distantPast) > ($1.messages.last?.timestamp ?? .distantPast) }
    }

    var body: some View {
        let list = conversations
        List {
            Group {
                WarmPageHeader(title: "短信") {
                    Menu {
                        Button { model.markMessagesRead(model.messages) } label: { Label("全部标为已读", systemImage: "checkmark.circle") }
                            .disabled(model.unreadMessageIDs.isEmpty)
                        Button(role: .destructive) { confirmingClear = true } label: { Label("清空全部短信", systemImage: "trash") }
                            .disabled(model.messages.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 20)).foregroundStyle(Warm.accent).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("更多操作")
                    WarmIconButton(systemName: "square.and.pencil", label: "新建短信") { showingComposer = true }
                }
                .warmListRow(leading: 0, trailing: 0)
                WarmSearchField(prompt: "搜索姓名、号码或内容", text: $search)
                    .padding(.bottom, 4)
                    .warmListRow()
                if list.isEmpty {
                    Group {
                        if search.isEmpty {
                            WarmEmptyState(systemImage: "message", title: "暂无短信", detail: "收到或发出的短信会显示在这里。",
                                           actionTitle: "新建短信") { showingComposer = true }
                        } else {
                            WarmEmptyState(systemImage: "magnifyingglass", title: "未找到短信", detail: "试试姓名、号码或其他关键词。")
                        }
                    }
                    .warmListRow()
                }
            }
            ForEach(Array(list.enumerated()), id: \.element.sender) { index, conversation in
                let unread = conversation.messages.contains { model.unreadMessageIDs.contains($0.id) }
                // The unread dot sits in the left margin, so the avatar lines up with the title.
                WarmConversationRow(sender: conversation.sender, messages: conversation.messages) { open(conversation.sender) }
                    .warmListRow(leading: 4, trailing: 20, separator: index < list.count - 1)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            SMSAudioPlayback.shared.stop()
                            model.deleteMessages(ids: Set(conversation.messages.map(\.id)))
                        } label: { Label("删除", systemImage: "trash") }
                        .tint(Warm.danger)
                        if unread {
                            Button { model.markMessagesRead(conversation.messages) } label: {
                                Label("已读", systemImage: "envelope.open")
                            }
                            .tint(Color(uiColor: .systemGray))
                        }
                    }
            }
            Color.clear.frame(height: 16).warmListRow()
        }
        .warmPlainList()
        .refreshable { await model.loadMessagesFromAgent() }
        .background(Warm.plain.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await contacts.loadIfAuthorized()
            await model.loadMessagesFromAgent(silently: true)
        }
        .onAppear { if pendingRecipient != nil { showingComposer = true } }
        .onChange(of: pendingRecipient) { recipient in if recipient != nil { showingComposer = true } }
        .sheet(isPresented: $showingComposer, onDismiss: { pendingRecipient = nil }) {
            MessageComposer(initialRecipient: pendingRecipient ?? "")
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("清空全部短信？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("删除全部", role: .destructive) {
                SMSAudioPlayback.shared.stop()
                model.deleteMessages(ids: Set(model.messages.map(\.id)))
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除此 iPhone 上 AirSIM 内的短信及其中的语音留言记录，不影响安卓手机和 voip.ms 上的记录。此操作无法撤销。")
        }
    }
}

extension SMSCarrierBrand {
    /// Spoken with the number (VoiceOver), since the logo itself is decorative.
    var displayName: String {
        switch self {
        case .mobile: return "中国移动"
        case .unicom: return "中国联通"
        case .telecom: return "中国电信"
        case .icbc: return "工商银行"
        case .ccb: return "建设银行"
        case .abc: return "农业银行"
        case .boc: return "中国银行"
        case .bocom: return "交通银行"
        case .cmb: return "招商银行"
        case .minsheng: return "民生银行"
        case .sf: return "顺丰速运"
        case .jd: return "京东物流"
        case .zto: return "中通快递"
        case .yto: return "圆通速递"
        }
    }
}

/// Conversation avatar: contact photo › service logo › contact initial › person glyph.
struct WarmSMSAvatar: View {
    let name: String?
    let photoData: Data?
    let brand: SMSCarrierBrand?
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    var body: some View {
        let size = min(side, 64)
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let brand {
                Image(brand.rawValue).resizable().scaledToFit().padding(size * 0.17)
                    .frame(width: size, height: size).background(Color.white)
            } else if let initial = name?.trimmingCharacters(in: .whitespacesAndNewlines).first {
                // Neutral like the system's monogram avatars; the accent is kept for state, not decoration.
                Warm.avatar.overlay {
                    Text(String(initial).uppercased()).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.white)
                }
            } else {
                Warm.avatar.overlay {
                    Image(systemName: "person.fill").font(.system(size: size * 0.46)).foregroundStyle(.white)
                        .offset(y: size * 0.06)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

private struct WarmConversationRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let sender: String
    let messages: [SMSMessage]
    let open: () -> Void

    var body: some View {
        let latest = messages.last
        let unread = messages.contains { model.unreadMessageIDs.contains($0.id) }
        let contact = contacts.contact(for: sender)
        let brand = contact == nil ? SMSCarrierBrand.match(sender) : nil
        let name = contact?.name ?? WarmPhone.format(sender)
        let tag = latest.flatMap { model.warmLineTag(agentID: $0.sourceAgentID, slot: $0.simSlot) }
        Button(action: open) {
            HStack(alignment: .top, spacing: 0) {
                Circle().fill(unread ? Warm.accent : Color.clear).frame(width: 8, height: 8)
                    .frame(width: 16, height: 44)
                WarmSMSAvatar(name: contact?.name, photoData: contact?.photoData, brand: brand)
                    .padding(.trailing, 12)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(name).font(unread ? .body.weight(.semibold) : .body.weight(.medium)).monospacedDigit()
                            .foregroundStyle(Warm.text).lineLimit(1).layoutPriority(1)
                        if let tag {
                            Text(tag).font(.caption).monospacedDigit().foregroundStyle(Warm.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let latest {
                            Text(WarmDate.list(latest.timestamp)).font(.subheadline).monospacedDigit().foregroundStyle(Warm.secondary)
                        }
                    }
                    Text(preview(latest)).font(.subheadline).foregroundStyle(Warm.secondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // List separators start under the text, not under the avatar.
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([brand?.displayName, name, unread ? "未读" : nil, preview(latest), latest.map(source)].compactMap { $0 }.joined(separator: "，"))
        .contextMenu {
            Button(role: .destructive) { model.deleteMessages(ids: Set(messages.map(\.id))) } label: { Label("删除会话", systemImage: "trash") }
        }
    }

    private func preview(_ message: SMSMessage?) -> String {
        guard let message else { return "" }
        var body = message.content
        if let audio = message.attachments?.first(where: { $0.kind == .audio }) {
            body = "[语音留言]" + (audio.duration.map { " " + WarmDate.clock($0) } ?? "")
        }
        return message.isOutgoing ? "我：" + body : body
    }

    private func source(_ message: SMSMessage) -> String {
        let label = model.warmSourceLabel(agentID: message.sourceAgentID, slot: message.simSlot)
        return label.hasPrefix("+") || label.first?.isNumber == true ? "经由 \(label)" : label
    }
}

// MARK: - Account (P11)

/// Settings-style groups without decoration: no icons, no stats line, no section captions.
struct WarmAccountView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let actions: WarmActions

    var body: some View {
        let agents = model.pairedAndroidAgents
        let current = model.warmCurrentLine
        let agent = model.currentAndroidAgent
        let online = agents.filter(\.isReachable).count
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WarmPageHeader(title: "我的") { EmptyView() }.padding(.bottom, -16)
                group {
                    row("默认线路", current?.title) { actions.pickLine(.defaultLine) }
                    divider
                    row("连接与设备", agents.isEmpty ? "未添加" : "\(online)/\(agents.count) 在线") { actions.openSettings([.connections]) }
                    divider
                    row("来电与短信", nil) { actions.openSettings([.calls]) }
                    divider
                    row("外观与偏好", settings.theme.title) { actions.openSettings([.preferences]) }
                }
                group {
                    row("连接状态", model.warmInCall ? "通话中" : (agent?.routeTitle ?? "无设备")) { actions.openSettings([.status]) }
                    divider
                    row("网络诊断", nil) { actions.openSettings([.help, .networkDiagnostics]) }
                    divider
                    row("帮助与诊断", nil) { actions.openSettings([.help]) }
                    divider
                    row("意见反馈", nil) { actions.openSettings([.feedback]) }
                }
                group {
                    row("关于 AirSIM", AppInformation.version) { actions.openSettings([.about]) }
                    divider
                    row("全部设置", nil) { actions.openSettings([]) }
                }
            }
            .padding(.bottom, 16)
        }
        .background(Warm.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var divider: some View { WarmHairline().padding(.leading, 16) }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content).warmCard().padding(.horizontal, 16)
    }

    private func row(_ title: String, _ value: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).font(.body).foregroundStyle(Warm.text)
                Spacer(minLength: 8)
                if let value {
                    Text(value).font(.body).monospacedDigit().foregroundStyle(Warm.secondary).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Warm.disabled)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
