import SwiftUI
import UIKit

// 暖橙主题的 App 外壳，按 Codex 设计稿实现（docs/design/warm-2026-11-20/DESIGN.md）。
// 原则：号码优先、平面列表、铜橙只用于操作与选中；系统字体，无阴影、无渐变。
// 通话界面、短信会话页、设置子页面沿用原有实现。

// MARK: - Tokens

enum Warm {
    static var accent: Color { Color(uiColor: AppTheme.warm.uiAccent) }
    static let background = Color(uiColor: WarmPalette.background)
    static let surface = Color(uiColor: WarmPalette.card)
    static let muted = Color(uiColor: WarmPalette.soft)
    static let text = Color(uiColor: WarmPalette.textPrimary)
    static let secondary = Color(uiColor: WarmPalette.textSecondary)
    static let disabled = Color(uiColor: WarmPalette.textDisabled)
    static let onAccent = Color(uiColor: WarmPalette.onAccent)
    static let accentSoft = Color(uiColor: WarmPalette.accentSoft)
    static let separator = Color(uiColor: WarmPalette.cardBorder)
    static let controlBorder = Color(uiColor: WarmPalette.controlBorder)
    static let positive = Color(uiColor: WarmPalette.positive)
    static let danger = Color(uiColor: WarmPalette.danger)
    static let warningText = Color(uiColor: WarmPalette.warningText)
    static let warningSurface = Color(uiColor: WarmPalette.warningSurface)
    static let disabledFill = Color(uiColor: WarmPalette.disabledFill)
}

extension View {
    /// Surface block (current line, settings groups): radius 12, hairline edge, no shadow.
    func warmCard(_ radius: CGFloat = 12) -> some View { modifier(WarmCardSurface(cornerRadius: radius)) }
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
            return slots.map {
                WarmLine(agentID: agent.id, slotID: $0.id, slotIndex: $0.slotIndex, number: $0.displayNumber, deviceName: agent.deviceName,
                         carrier: $0.carrierName, isVoipms: agent.isVoipms, route: agent.routeTitle, online: agent.isReachable)
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

struct WarmSectionTitle: View {
    let title: String
    var action: (title: String, run: () -> Void)? = nil
    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Warm.text).accessibilityAddTraits(.isHeader)
            Spacer()
            if let action {
                Button(action.title, action: action.run)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Warm.accent)
                    .frame(minHeight: 44)
            }
        }
        .frame(minHeight: 44)
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

struct WarmDefaultTag: View {
    var body: some View {
        Text("默认")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Warm.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Warm.accentSoft, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
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

struct WarmSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(isEnabled ? Warm.text : Warm.disabled)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(configuration.isPressed ? Warm.muted : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isEnabled ? Warm.controlBorder : Warm.separator, lineWidth: 1))
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

    var body: some View {
        ZStack {
            layer(.home) {
                NavigationStack {
                    WarmHomeView(actions: actions).safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
                }
            }
            layer(.calls) {
                WarmCallsView(segment: callsSegment, actions: actions) { tabBar }
            }
            layer(.messages) {
                NavigationStack {
                    WarmMessagesView(pendingRecipient: $pendingSMSRecipient, open: openConversation)
                        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
                        .navigationDestination(isPresented: $showingConversation) {
                            if let sender = conversationSender { MessageThreadView(sender: sender).id(sender) }
                        }
                }
            }
            layer(.account) {
                NavigationStack {
                    WarmAccountView(actions: actions).safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
                }
            }
        }
        .background(Warm.background.ignoresSafeArea())
        .sheet(item: $settingsRoute) { route in
            AirSIMSettingsView(initialPath: route.path)
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

    /// All four roots stay alive (navigation and scroll state); only one is visible.
    @ViewBuilder
    private func layer<Content: View>(_ which: WarmTab, @ViewBuilder content: () -> Content) -> some View {
        let visible = tab == which
        content()
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .zIndex(visible ? 1 : 0)
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
                                            .foregroundStyle(Warm.onAccent)
                                            .padding(.horizontal, 4)
                                            .frame(minWidth: 16, minHeight: 16)
                                            .background(Warm.accent, in: Capsule())
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
        .background(Warm.surface.ignoresSafeArea(edges: .bottom))
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
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(line.title).font(.body).monospacedDigit().foregroundStyle(disabled ? Warm.disabled : Warm.text)
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
            .frame(minHeight: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Home (P01, P15)

struct WarmHomeView: View {
    @EnvironmentObject private var model: AppModel
    let actions: WarmActions

    var body: some View {
        let agents = model.pairedAndroidAgents
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WarmPageHeader(title: "AirSIM") {
                    WarmIconButton(systemName: "plus", label: "添加设备") { actions.openSettings([.add]) }
                }
                if agents.isEmpty {
                    WarmEmptyState(systemImage: "simcard", title: "还没有线路",
                                   detail: "添加安卓手机或 voip.ms 号码，在这台 iPhone 上打电话、收短信。",
                                   actionTitle: "添加设备") { actions.openSettings([.add]) }
                } else {
                    content.padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 8)
        }
        .background(Warm.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var content: some View {
        let current = model.warmCurrentLine
        let others = model.warmLines.filter { $0 != current }
        let agents = model.pairedAndroidAgents
        VStack(alignment: .leading, spacing: 0) {
            WarmSectionTitle(title: "当前线路", action: ("切换", { actions.pickLine(.defaultLine) }))
            if let current { currentBlock(current) }
            summary.padding(.top, 8)
            if !others.isEmpty {
                WarmSectionTitle(title: "其他线路").padding(.top, 16)
                ForEach(Array(others.prefix(3).enumerated()), id: \.element.id) { index, line in
                    Button { model.warmSelect(line) } label: { lineRow(line) }
                        .buttonStyle(.plain)
                        .accessibilityHint("设为默认线路")
                    if index < min(others.count, 3) - 1 { WarmHairline() }
                }
                if others.count > 3 {
                    Button("查看全部线路") { actions.pickLine(.defaultLine) }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Warm.accent).frame(minHeight: 44)
                }
            }
            WarmSectionTitle(title: "设备", action: ("管理", { actions.openSettings([.connections]) })).padding(.top, 16)
            ForEach(Array(agents.prefix(3).enumerated()), id: \.element.id) { index, agent in
                Button { actions.openSettings([.connections, .device(agent.id)]) } label: { deviceRow(agent) }
                    .buttonStyle(.plain)
                if index < min(agents.count, 3) - 1 { WarmHairline() }
            }
            if agents.count > 3 {
                Button("查看全部设备") { actions.openSettings([.connections]) }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Warm.accent).frame(minHeight: 44)
            }
        }
    }

    private func currentBlock(_ line: WarmLine) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(line.title)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Warm.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("当前线路 \(line.title)")
            HStack(spacing: 8) {
                Text(line.source).font(.subheadline).foregroundStyle(Warm.secondary).lineLimit(2)
                Text("·").font(.subheadline).foregroundStyle(Warm.secondary)
                WarmRouteLabel(route: line.route, online: line.online)
                Spacer(minLength: 4)
                WarmDefaultTag()
            }
            .padding(.top, 8)
            if !line.online {
                Text("设备离线，暂时无法拨号或发送短信").font(.subheadline).foregroundStyle(Warm.warningText).padding(.top, 8)
            }
            HStack(spacing: 12) {
                Button { actions.openTab(.dial) } label: { Label("拨号", systemImage: "phone") }
                    .buttonStyle(WarmPrimaryButtonStyle())
                Button { actions.compose(nil) } label: { Label("发短信", systemImage: "message") }
                    .buttonStyle(WarmSecondaryButtonStyle())
            }
            .disabled(!line.online)
            .padding(.top, 16)
        }
        .padding(16)
        .warmCard()
    }

    @ViewBuilder
    private var summary: some View {
        let missed = model.unseenMissedCallIDs.count
        let unread = model.warmUnreadConversations
        if missed > 0 || unread > 0 {
            HStack(spacing: 20) {
                if missed > 0 {
                    summaryLink(icon: "phone.arrow.down.left", title: "未接来电", count: missed) { actions.openTab(.recents) }
                }
                if unread > 0 {
                    summaryLink(icon: "message", title: "未读短信", count: unread) { actions.openTab(.messages) }
                }
                Spacer()
            }
        }
    }

    private func summaryLink(icon: String, title: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Warm.secondary)
                Text(title).font(.subheadline).foregroundStyle(Warm.text)
                Text("\(count)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Warm.accent)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(count)")
    }

    private func lineRow(_ line: WarmLine) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(line.title).font(.body).monospacedDigit().foregroundStyle(Warm.text)
                Text(line.source).font(.subheadline).foregroundStyle(Warm.secondary)
            }
            Spacer(minLength: 8)
            WarmRouteLabel(route: line.route, online: line.online)
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }

    private func deviceRow(_ agent: AndroidAgentPresentation) -> some View {
        let lines = model.simSlots(for: agent.id).count
        let battery = agent.isVoipms ? nil : model.androidBattery(for: agent.id)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: agent.isVoipms ? "network" : "smartphone")
                .font(.system(size: 20)).foregroundStyle(Warm.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.deviceName).font(.body).foregroundStyle(Warm.text).lineLimit(2)
                Text("\(agent.isVoipms ? "voip.ms" : "安卓") · \(max(lines, 1)) 条线路").font(.subheadline).foregroundStyle(Warm.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                WarmRouteLabel(route: agent.routeTitle, online: agent.isReachable)
                if let battery {
                    Text("· \(battery.percent)%").font(.caption).monospacedDigit().foregroundStyle(Warm.secondary)
                }
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Warm.disabled)
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }
}

// MARK: - Calls (P02–P06, P16–P18, P21–P23)

struct WarmCallsView<TabBar: View>: View {
    @EnvironmentObject private var model: AppModel
    @Binding var segment: PhoneTab
    let actions: WarmActions
    @ViewBuilder var tabBar: () -> TabBar
    @State private var path: [String] = []
    @State private var tick = 0
    @State private var confirmingVoicemailClear = false

    private var unheardVoicemails: Int {
        _ = tick
        let heard = WarmHeardVoicemails.all()
        return model.warmVoicemails.filter { !heard.contains($0.id) }.count
    }

    private var status: (route: String, online: Bool) {
        if model.warmInCall { return ("通话中", true) }
        guard let line = model.warmCurrentLine else { return ("无线路", false) }
        return (line.route, line.online)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                WarmPageHeader(title: "通话") {
                    if segment == .voicemail, !model.warmVoicemails.isEmpty {
                        Menu {
                            Button("清空全部语音留言", role: .destructive) { confirmingVoicemailClear = true }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 20)).foregroundStyle(Warm.accent).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("更多操作")
                    } else {
                        WarmRouteLabel(route: status.route, online: status.online).padding(.trailing, 10)
                    }
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
            .background(Warm.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0, content: tabBar)
            .navigationDestination(for: String.self) { contactID in
                WarmContactDetail(contactID: contactID, actions: actions) { number in
                    path = []
                    model.numberInput = number
                    segment = .dial
                }
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

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                let selected = selection == item.tab
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { selection = item.tab }
                } label: {
                    HStack(spacing: 4) {
                        Text(item.title).font(.subheadline.weight(selected ? .semibold : .medium)).lineLimit(1)
                        if item.count > 0 {
                            Text(item.count > 9 ? "9+" : "\(item.count)")
                                .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Warm.accent)
                        }
                    }
                    .foregroundStyle(selected ? Warm.text : Warm.secondary)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(selected ? Warm.surface : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.count > 0 ? "\(item.title)，\(item.count)" : item.title)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .background(Warm.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                                .fill(canCall ? Warm.accent : Warm.disabledFill)
                                .frame(width: 64, height: 64)
                                .overlay(Image(systemName: "phone.fill").font(.system(size: 27))
                                    .foregroundStyle(canCall ? Warm.onAccent : Warm.disabled))
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
        Text(model.numberInput.isEmpty ? "输入号码" : model.numberInput)
            .font(.largeTitle.weight(.regular))
            .monospacedDigit()
            .foregroundStyle(model.numberInput.isEmpty ? Warm.disabled : Warm.text)
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
                    .font(.subheadline).monospacedDigit().foregroundStyle(Warm.text).lineLimit(1).minimumScaleFactor(0.85)
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
    let actions: WarmActions
    let showVoicemail: () -> Void
    @State private var missedOnly = false
    @State private var detail: CallRecord?

    var body: some View {
        let records = model.callHistory.filter { !missedOnly || ($0.direction == "incoming" && $0.missed) }
        let sections = Dictionary(grouping: records) { Calendar.current.startOfDay(for: $0.startedAt) }
            .sorted { $0.key > $1.key }
        let missedCount = model.callHistory.filter { $0.direction == "incoming" && $0.missed }.count
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 20) {
                    filter("全部", selected: !missedOnly) { missedOnly = false }
                    filter(missedCount > 0 ? "未接 \(missedCount)" : "未接", selected: missedOnly) { missedOnly = true }
                    Spacer()
                }
                if records.isEmpty {
                    if missedOnly {
                        WarmEmptyState(systemImage: "phone", title: "没有未接来电")
                    } else {
                        WarmEmptyState(systemImage: "phone", title: "暂无通话记录", detail: "拨打或接听的电话会显示在这里。",
                                       actionTitle: "去拨号") { actions.openTab(.dial) }
                    }
                }
                ForEach(sections, id: \.key) { day, calls in
                    WarmSectionTitle(title: WarmDate.day(day)).padding(.top, 8)
                    let sorted = calls.sorted { $0.startedAt > $1.startedAt }
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, call in
                        WarmRecentRow(call: call, hasVoicemail: hasVoicemail(call)) { detail = call }
                        if index < sorted.count - 1 { WarmHairline().padding(.leading, 30) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .refreshable { await model.refreshCallHistory() }
        .onAppear { if !model.callHistory.isEmpty { model.markMissedCallsSeen() } }
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
                .foregroundStyle(selected ? Warm.accent : Warm.secondary)
                .frame(minHeight: 44)
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
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: call.missed ? "phone.down" : incoming ? "phone.arrow.down.left" : "phone.arrow.up.right")
                    .font(.system(size: 16))
                    .foregroundStyle(call.missed ? Warm.danger : Warm.secondary)
                    .frame(width: 18)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(WarmPhone.name(call.number, contacts: contacts))
                            .font(.body).monospacedDigit().foregroundStyle(Warm.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        // Rows sit under a day heading, so they carry only the time.
                        Text(call.startedAt.formatted(date: .omitted, time: .shortened)).font(.caption).monospacedDigit().foregroundStyle(Warm.secondary)
                    }
                    Text((incoming ? "打到 " : "经由 ") + model.warmSourceLabel(agentID: call.sourceAgentID, slot: call.slotIndex.map { "SIM \($0 + 1)" }))
                        .font(.subheadline).monospacedDigit().foregroundStyle(Warm.secondary)
                    HStack(spacing: 0) {
                        if call.missed {
                            Text("未接").foregroundStyle(Warm.danger)
                            if hasVoicemail { Text(" · 有语音留言").foregroundStyle(Warm.secondary) }
                        } else {
                            Text(incoming ? "呼入" : "呼出")
                            Text(call.connectedDuration.map { " · " + WarmDate.duration($0) } ?? "")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Warm.secondary)
                }
                Image(systemName: "info.circle").font(.system(size: 20)).foregroundStyle(Warm.accent)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
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
                    VStack(spacing: 0) {
                        fact("时间", WarmDate.full(call.startedAt))
                        WarmHairline()
                        fact("通话状态", call.missed ? "未接" : incoming ? "呼入" : "呼出", danger: call.missed)
                        WarmHairline()
                        fact("经由线路", model.warmSourceLabel(agentID: call.sourceAgentID, slot: call.slotIndex.map { "SIM \($0 + 1)" }),
                             detail: line.map { "\($0.source) · \($0.route)" })
                        if let duration = call.connectedDuration {
                            WarmHairline()
                            fact("时长", WarmDate.duration(duration))
                        }
                    }
                    .padding(.top, 20)
                    if model.warmInCall {
                        WarmNotice(text: "通话中，暂不能再次拨号。").padding(.top, 16)
                    }
                    if let number = RecentCallDialPolicy.numberToDial(call.number) {
                        HStack(spacing: 12) {
                            Button {
                                dismiss()
                                model.warmDial(number, on: line?.online == true ? line : nil)
                            } label: { Label("回拨", systemImage: "phone") }
                                .buttonStyle(WarmPrimaryButtonStyle())
                                .disabled(model.warmInCall)
                            Button { dismiss(); actions.message(number) } label: { Label("发短信", systemImage: "message") }
                                .buttonStyle(WarmSecondaryButtonStyle())
                        }
                        .padding(.top, 20)
                    }
                    if hasVoicemail {
                        Button(action: playVoicemail) {
                            HStack {
                                Text("播放语音留言").font(.body).foregroundStyle(Warm.accent)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Warm.disabled)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 12)
                    }
                }
                .padding(20)
            }
            .background(Warm.surface.ignoresSafeArea())
            .navigationTitle("通话详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
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
                    Text(contact.phones.isEmpty ? "这个联系人没有电话号码" : "\(contact.phones.count) 个号码")
                        .font(.subheadline).foregroundStyle(Warm.secondary).padding(.top, 4)
                    ForEach(Array(contact.phones.enumerated()), id: \.offset) { index, number in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(contact.phones.count > 1 ? "号码 \(index + 1)" : "电话").font(.caption).foregroundStyle(Warm.secondary)
                            Text(WarmPhone.format(number)).font(.body).monospacedDigit().foregroundStyle(Warm.text).textSelection(.enabled)
                            HStack(spacing: 12) {
                                Button { dial(number) } label: { Text("拨打") }.buttonStyle(WarmPrimaryButtonStyle())
                                    .disabled(model.warmInCall)
                                Button { actions.message(number) } label: { Text("发短信") }.buttonStyle(WarmSecondaryButtonStyle())
                            }
                        }
                        .padding(.top, 24)
                    }
                    WarmHairline().padding(.top, 24)
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
        .background(Warm.background.ignoresSafeArea())
        .navigationTitle("联系人详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .tint(Warm.accent)
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if voicemails.isEmpty {
                    if hasVoipms {
                        WarmEmptyState(systemImage: "recordingtape", title: "暂无语音留言", detail: "收到的语音留言会显示在这里。")
                    } else {
                        WarmEmptyState(systemImage: "recordingtape", title: "需要 voip.ms 线路", detail: "语音信箱仅适用于 voip.ms 号码。",
                                       actionTitle: "添加设备") { actions.openSettings([.add]) }
                    }
                }
                ForEach(sections, id: \.key) { day, items in
                    WarmSectionTitle(title: WarmDate.day(day)).padding(.top, 8)
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, message in
                        WarmVoicemailRow(message: message, expanded: expanded == message.id, tick: tick, actions: actions) {
                            expanded = message.id
                        }
                        if index < items.count - 1 { WarmHairline() }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(heard ? Color.clear : Warm.accent).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(WarmPhone.name(message.sender, contacts: contacts))
                    .font(heard ? .body : .body.weight(.semibold)).monospacedDigit().foregroundStyle(Warm.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(message.timestamp.formatted(date: .omitted, time: .shortened)).font(.caption).monospacedDigit().foregroundStyle(Warm.secondary)
            }
            Text("打到 " + model.warmSourceLabel(agentID: message.sourceAgentID, slot: message.simSlot))
                .font(.subheadline).monospacedDigit().foregroundStyle(Warm.secondary)
                .padding(.leading, 16).padding(.top, 3)
            HStack(spacing: 10) {
                Button(action: toggle) {
                    Circle().fill(Warm.accentSoft).frame(width: 44, height: 44)
                        .overlay {
                            if loading {
                                ProgressView().tint(Warm.accent)
                            } else {
                                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 17))
                                    .foregroundStyle(Warm.accent).offset(x: playing ? 0 : 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? "暂停语音留言" : "播放语音留言")
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
                } else {
                    Text((heard ? "已听" : "未听") + (audio?.duration.map { " · " + WarmDate.clock($0) } ?? ""))
                        .font(.subheadline).monospacedDigit().foregroundStyle(Warm.secondary)
                    Spacer()
                }
            }
            .padding(.leading, 16).padding(.top, 8)
            if expanded, let number = RecentCallDialPolicy.numberToDial(message.sender) {
                HStack {
                    Button { model.warmDial(number, on: model.warmLine(agentID: message.sourceAgentID, slotIndex: slotIndex)) } label: {
                        Label("回拨", systemImage: "phone")
                    }
                    .disabled(model.warmInCall)
                    Spacer()
                    Button { actions.message(number) } label: { Label("发短信", systemImage: "message") }
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(Warm.accent)
                .frame(minHeight: 44)
                .padding(.leading, 16).padding(.top, 4)
            }
        }
        .padding(.vertical, 12)
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                WarmPageHeader(title: "短信") {
                    Menu {
                        Button("清空全部短信", role: .destructive) { confirmingClear = true }.disabled(model.messages.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 20)).foregroundStyle(Warm.accent).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("更多操作")
                    WarmIconButton(systemName: "square.and.pencil", label: "新建短信") { showingComposer = true }
                }
                WarmSearchField(prompt: "搜索姓名、号码或内容", text: $search)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                if list.isEmpty {
                    if search.isEmpty {
                        WarmEmptyState(systemImage: "message", title: "暂无短信", detail: "收到或发出的短信会显示在这里。",
                                       actionTitle: "新建短信") { showingComposer = true }
                    } else {
                        WarmEmptyState(systemImage: "magnifyingglass", title: "未找到短信", detail: "试试姓名、号码或其他关键词。")
                    }
                }
                ForEach(Array(list.enumerated()), id: \.element.sender) { index, conversation in
                    WarmConversationRow(sender: conversation.sender, messages: conversation.messages) { open(conversation.sender) }
                        .padding(.horizontal, 20)
                    if index < list.count - 1 { WarmHairline().padding(.leading, 36) }
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { await model.loadMessagesFromAgent() }
        .background(Warm.background.ignoresSafeArea())
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

private struct WarmConversationRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let sender: String
    let messages: [SMSMessage]
    let open: () -> Void

    var body: some View {
        let latest = messages.last
        let unread = messages.contains { model.unreadMessageIDs.contains($0.id) }
        let name = contacts.contact(for: sender)?.name ?? WarmPhone.format(sender)
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(unread ? Warm.accent : Color.clear).frame(width: 8, height: 8).padding(.top, 7)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(name).font(unread ? .body.weight(.semibold) : .body).monospacedDigit().foregroundStyle(Warm.text).lineLimit(1)
                        Spacer(minLength: 8)
                        if let latest {
                            Text(WarmDate.list(latest.timestamp)).font(.caption).monospacedDigit().foregroundStyle(Warm.secondary)
                        }
                    }
                    Text(preview(latest)).font(.subheadline).foregroundStyle(Warm.text.opacity(unread ? 1 : 0.85))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if let latest {
                        Text(source(latest)).font(.caption).monospacedDigit().foregroundStyle(Warm.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(unread ? "\(name)，未读" : name)
        .contextMenu {
            Button(role: .destructive) { model.deleteMessages(ids: Set(messages.map(\.id))) } label: { Label("删除会话", systemImage: "trash") }
        }
    }

    private func preview(_ message: SMSMessage?) -> String {
        guard let message else { return "" }
        var body = message.content
        if let audio = message.attachments?.first(where: { $0.kind == .audio }) {
            body = "[语音留言]" + (audio.duration.map { " · " + WarmDate.clock($0) } ?? "")
        }
        return message.isOutgoing ? "我：" + body : body
    }

    private func source(_ message: SMSMessage) -> String {
        let label = model.warmSourceLabel(agentID: message.sourceAgentID, slot: message.simSlot)
        return label.hasPrefix("+") || label.first?.isNumber == true ? "经由 \(label)" : label
    }
}

// MARK: - Account (P11)

struct WarmAccountView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let actions: WarmActions

    var body: some View {
        let agents = model.pairedAndroidAgents
        let current = model.warmCurrentLine
        let agent = model.currentAndroidAgent
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WarmPageHeader(title: "我的") { EmptyView() }
                VStack(alignment: .leading, spacing: 2) {
                    Text("AirSIM").font(.headline).foregroundStyle(Warm.text)
                    Text("\(model.warmLines.count) 条线路 · \(agents.count) 台设备").font(.subheadline).foregroundStyle(Warm.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                group("通用") {
                    row("simcard", "默认线路", current?.title) { actions.pickLine(.defaultLine) }
                    divider
                    row("antenna.radiowaves.left.and.right", "连接与设备", nil) { actions.openSettings([.connections]) }
                    divider
                    row("phone.bubble", "来电与短信", nil) { actions.openSettings([.calls]) }
                    divider
                    row("circle.lefthalf.filled", "外观与偏好", settings.theme.title) { actions.openSettings([.preferences]) }
                    divider
                    row("dot.radiowaves.left.and.right", "连接状态", model.warmInCall ? "通话中" : (agent?.routeTitle ?? "无设备")) {
                        actions.openSettings([.status])
                    }
                }
                group("支持") {
                    row("stethoscope", "帮助与诊断", nil) { actions.openSettings([.help]) }
                    divider
                    row("bubble.left.and.text.bubble.right", "意见反馈", nil) { actions.openSettings([.feedback]) }
                    divider
                    row("info.circle", "关于 AirSIM", nil) { actions.openSettings([.about]) }
                    divider
                    row("gearshape", "全部设置", nil) { actions.openSettings([]) }
                }
            }
            .padding(.bottom, 8)
        }
        .background(Warm.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var divider: some View { WarmHairline().padding(.leading, 52) }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WarmSectionTitle(title: title).padding(.horizontal, 20)
            VStack(spacing: 0, content: content).warmCard().padding(.horizontal, 20)
        }
        .padding(.top, 8)
    }

    private func row(_ icon: String, _ title: String, _ value: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Warm.secondary).frame(width: 24)
                Text(title).font(.body).foregroundStyle(Warm.text)
                Spacer(minLength: 8)
                if let value {
                    Text(value).font(.subheadline).monospacedDigit().foregroundStyle(Warm.secondary).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Warm.disabled)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
