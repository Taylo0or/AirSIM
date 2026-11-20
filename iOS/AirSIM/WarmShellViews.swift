import SwiftUI
import UIKit

// 暖橙主题的整套界面：首页 / 通话（拨号·最近·联系人·语音信箱）/ 短信 / 我的。
// 只替换外壳与列表页；通话界面、短信会话、设置子页面沿用原有实现。

// MARK: - Design tokens

enum Warm {
    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        func ui(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
    static var accent: Color { AppTheme.warm.accent }
    static let background = Color(uiColor: WarmPalette.background)
    static let card = Color(uiColor: WarmPalette.card)
    static let border = Color(uiColor: WarmPalette.cardBorder)
    static let soft = Color(uiColor: WarmPalette.soft)
    static let accentSoft = Color(uiColor: WarmPalette.accentSoft)
    static let ink = color(0x1E1A17, 0xF4EFE9)
    static let muted = color(0x8A8178, 0x9F968C)
    static let track = color(0xECE7E0, 0x2A2521)
    static let noticeBackground = color(0xFCF3DA, 0x342A17)
    static let noticeText = color(0xA2761C, 0xE3B65E)
    static let online = Color(red: 0.24, green: 0.66, blue: 0.43)
    static let outgoing = Color(red: 0.15, green: 0.62, blue: 0.42)
    static let missed = Color(red: 0.86, green: 0.25, blue: 0.22)
    static var gradient: LinearGradient {
        LinearGradient(colors: WarmPalette.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static func title(_ text: String) -> some View {
        Text(text).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(ink)
    }
}

extension View {
    func warmCard(_ radius: CGFloat = 22) -> some View { modifier(WarmCardSurface(cornerRadius: radius)) }
}

// MARK: - Phone numbers and lines

enum WarmPhone {
    static func digits(_ value: String) -> String { String(value.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) && $0.isASCII }) }

    static func isNANP(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let number = digits(trimmed)
        if trimmed.hasPrefix("+1") { return number.count == 11 }
        if trimmed.hasPrefix("+") { return false }
        if number.count == 10, let first = number.first, first != "0", first != "1" { return true }
        return false
    }

    /// "+1 (672) 205-1216", "138 0013 8000"; short codes and others stay as given.
    static func format(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "未知号码" }
        let number = digits(raw)
        if isNANP(raw) {
            let d = Array(number.suffix(10))
            return "+1 (\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
        }
        var mainland = number
        let international = raw.hasPrefix("+86")
        if international { mainland = String(number.dropFirst(2)) }
        if mainland.count == 11, mainland.hasPrefix("1"), international || !raw.hasPrefix("+") {
            let d = Array(mainland)
            return "\(international ? "+86 " : "")\(String(d[0..<3])) \(String(d[3..<7])) \(String(d[7..<11]))"
        }
        return raw
    }

    private static let canadianAreaCodes: Set<String> = [
        "204", "226", "236", "249", "250", "263", "289", "306", "343", "354", "365", "367", "368", "382", "403",
        "416", "418", "428", "431", "437", "438", "450", "468", "474", "506", "514", "519", "548", "579", "581",
        "584", "587", "604", "613", "639", "647", "672", "683", "705", "709", "742", "753", "778", "780", "782",
        "807", "819", "825", "867", "873", "879", "902", "905",
    ]

    static func region(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "" }
        if isNANP(raw) { return canadianAreaCodes.contains(String(digits(raw).suffix(10).prefix(3))) ? "CA" : "US" }
        let number = digits(raw)
        if raw.hasPrefix("+86") || (!raw.hasPrefix("+") && number.count == 11 && number.hasPrefix("1")) { return "CN" }
        if raw.hasPrefix("+852") { return "HK" }
        if raw.hasPrefix("+44") { return "UK" }
        if raw.hasPrefix("+61") { return "AU" }
        return ""
    }

    @MainActor static func name(_ number: String?, contacts: ContactStore) -> String {
        guard let number, !number.isEmpty else { return "未知号码" }
        return contacts.contact(for: number)?.name ?? format(number)
    }
}

/// One callable / textable line: a SIM slot of an Android Agent or a voip.ms DID.
struct WarmLine: Identifiable, Equatable {
    let agentID: String
    let slotID: String?
    let number: String?
    let deviceName: String
    let carrier: String?
    let online: Bool
    var id: String { "\(agentID)|\(slotID ?? "-")" }
    var title: String { number.map { WarmPhone.format($0) } ?? deviceName }
    var subtitle: String {
        [deviceName, carrier].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != title }.joined(separator: " · ")
    }
}

extension AndroidAgentPresentation {
    var isReachable: Bool { cloudOnline || vowlanOnline || bluetoothOnline }
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
                return [WarmLine(agentID: agent.id, slotID: nil, number: agent.phoneNumber, deviceName: agent.deviceName,
                                 carrier: agent.agentKindTitle, online: agent.isReachable)]
            }
            return slots.map {
                WarmLine(agentID: agent.id, slotID: $0.id, number: $0.displayNumber, deviceName: agent.deviceName,
                         carrier: $0.carrierName ?? $0.label, online: agent.isReachable)
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

    /// Makes `line` the line for the next call / new message. Never during a call.
    @discardableResult
    func warmSelect(_ line: WarmLine) -> Bool {
        guard !callLifecycleSnapshot.state.representsCall, pendingOutgoingCall == nil else {
            errorMessage = "通话中不能切换线路"
            return false
        }
        if currentAndroidAgent?.id != line.agentID { bindAndroidAgent(line.agentID) }
        if let slot = line.slotID { selectSIMSlot(slot, for: line.agentID) }
        return true
    }

    var warmVoicemails: [SMSMessage] {
        messages.filter { $0.attachments?.contains { $0.kind == .audio } == true }.sorted { $0.timestamp > $1.timestamp }
    }
}

enum WarmLineLabel {
    static func line(agentID: String?, slot: String?) -> String? {
        guard let slot = slot?.trimmingCharacters(in: .whitespacesAndNewlines), !slot.isEmpty else { return nil }
        let name = SIMLineDisplay.name(agentID: agentID, line: slot)
        return name.hasPrefix("SIM ") ? name : WarmPhone.format(name)
    }
    static func forCall(_ call: CallRecord) -> String? {
        guard let index = call.slotIndex, index >= 0 else { return nil }
        return line(agentID: call.sourceAgentID, slot: "SIM \(index + 1)")
    }
    static func forMessage(_ message: SMSMessage) -> String? { line(agentID: message.sourceAgentID, slot: message.simSlot) }
}

enum WarmDate {
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }
    /// "13:14", "昨天 13:14", "11月19日 13:14".
    static func dayAndTime(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(date) ? time : "\(monthDay(date)) \(time)"
    }
    static func monthDay(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded())
        return value >= 60 ? "\(value / 60)分\(value % 60)秒" : "\(value)秒"
    }
}

// MARK: - Shared pieces

struct WarmRegionBadge: View {
    let number: String?
    var size: CGFloat = 46
    var body: some View {
        let region = WarmPhone.region(number)
        Circle()
            .fill(Warm.soft)
            .frame(width: size, height: size)
            .overlay {
                if region.isEmpty {
                    Image(systemName: "simcard").font(.system(size: size * 0.38, weight: .medium)).foregroundStyle(Warm.accent)
                } else {
                    Text(region).font(.system(size: size * 0.32, weight: .semibold, design: .rounded)).foregroundStyle(Warm.accent)
                }
            }
    }
}

struct WarmStatusDot: View {
    let online: Bool
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(online ? Warm.online : Warm.muted.opacity(0.6)).frame(width: 9, height: 9)
            Text(online ? "在线" : "离线").font(.subheadline).foregroundStyle(Warm.muted)
        }
    }
}

struct WarmPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .frame(minHeight: 50)
            .background(Warm.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct WarmEmptyState: View {
    let title: String
    let systemImage: String
    var detail: String? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 34, weight: .light)).foregroundStyle(Warm.accent.opacity(0.7))
            Text(title).font(.headline).foregroundStyle(Warm.ink)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(Warm.muted).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
    }
}

private struct WarmChevron: View {
    var color: Color = Warm.muted
    var body: some View { Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(color) }
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
        case .account: return "person"
        }
    }
    var selectedIcon: String {
        switch self {
        case .calls: return "circle.grid.3x3.fill"
        default: return icon + ".fill"
        }
    }
}

private struct WarmSettingsRoute: Identifiable {
    let id = UUID()
    let path: [AirSIMSettingsPage]
}

struct WarmShellView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appUpdates: AppUpdateController
    @EnvironmentObject private var contacts: ContactStore
    @Binding var phoneTab: PhoneTab
    @Binding var pendingSMSRecipient: String?
    @Binding var conversationSender: String?
    @Binding var showingConversation: Bool
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    let openConversation: (String) -> Void
    @AppStorage("airsim.warm.calls-segment") private var lastCallsSegment = PhoneTab.dial.rawValue
    @State private var settingsRoute: WarmSettingsRoute?

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

    private func openSettings(_ path: [AirSIMSettingsPage]) { settingsRoute = WarmSettingsRoute(path: path) }

    private var tabBar: some View {
        WarmTabBar(selection: tab, select: select,
                   badges: [.calls: model.unseenMissedCallIDs.count, .messages: model.unreadMessageIDs.count])
    }

    var body: some View {
        ZStack {
            layer(.home) {
                NavigationStack {
                    WarmHomeView(openTab: { phoneTab = $0 }, openSettings: openSettings)
                        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
                }
            }
            layer(.calls) {
                NavigationStack {
                    WarmCallsView(segment: callsSegment, onCall: onCall, onMessage: onMessage)
                        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
                }
            }
            layer(.messages) {
                NavigationStack {
                    WarmMessagesView(pendingRecipient: $pendingSMSRecipient, open: openConversation)
                        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
                        .navigationDestination(isPresented: $showingConversation) {
                            if let sender = conversationSender {
                                MessageThreadView(sender: sender).id(sender)
                            }
                        }
                }
            }
            layer(.account) {
                NavigationStack {
                    WarmAccountView(openSettings: openSettings, openTab: { phoneTab = $0 })
                        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
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
    }

    /// All four roots stay alive (navigation state, scroll position); only one is visible.
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
        HStack(spacing: 0) {
            ForEach(WarmTab.allCases, id: \.self) { item in
                let selected = item == selection
                Button { select(item) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: selected ? item.selectedIcon : item.icon)
                            .font(.system(size: 22, weight: selected ? .semibold : .regular))
                            .frame(height: 26)
                            .overlay(alignment: .topTrailing) {
                                if let count = badges[item], count > 0 {
                                    Text(count > 99 ? "99+" : "\(count)")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .frame(minWidth: 18, minHeight: 18)
                                        .background(Warm.accent, in: Capsule())
                                        .offset(x: 12, y: -6)
                                }
                            }
                        Text(item.title).font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(selected ? Warm.accent : Warm.muted)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.top, 6)
        .background(Warm.card.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Warm.border).frame(height: 1) }
    }
}

// MARK: - Line picker

struct WarmLinePicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var title = "选择线路"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let lines = model.warmLines
                    if lines.isEmpty {
                        WarmEmptyState(title: "还没有线路", systemImage: "simcard", detail: "在「我的」里添加安卓手机或 voip.ms 号码")
                    }
                    ForEach(Array(Dictionary(grouping: lines, by: \.agentID).keys.sorted()), id: \.self) { agentID in
                        let group = lines.filter { $0.agentID == agentID }
                        if let first = group.first {
                            HStack {
                                Text(first.deviceName).font(.footnote.weight(.semibold)).foregroundStyle(Warm.muted)
                                Spacer()
                                WarmStatusDot(online: first.online)
                            }
                            .padding(.horizontal, 6)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(group.enumerated()), id: \.element.id) { index, line in
                                Button {
                                    if model.warmSelect(line) { dismiss() }
                                } label: {
                                    WarmLineRow(line: line, isCurrent: line == model.warmCurrentLine)
                                }
                                .buttonStyle(.plain)
                                if index < group.count - 1 { Divider().padding(.leading, 80) }
                            }
                        }
                        .warmCard(20)
                    }
                }
                .padding(20)
            }
            .background(Warm.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .tint(Warm.accent)
        .presentationDetents([.medium, .large])
    }
}

struct WarmLineRow: View {
    let line: WarmLine
    let isCurrent: Bool
    var showsChevron = true

    var body: some View {
        HStack(spacing: 14) {
            WarmRegionBadge(number: line.number)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Warm.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !line.subtitle.isEmpty {
                    Text(line.subtitle).font(.subheadline).foregroundStyle(Warm.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isCurrent {
                Text("默认")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Warm.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Warm.accentSoft, in: Capsule())
            }
            if showsChevron { WarmChevron() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - Home

struct WarmHomeView: View {
    @EnvironmentObject private var model: AppModel
    let openTab: (PhoneTab) -> Void
    let openSettings: ([AirSIMSettingsPage]) -> Void
    @State private var showingLines = false

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: return "早上好"
        case 11..<13: return "中午好"
        case 13..<18: return "下午好"
        case 18..<23: return "晚上好"
        default: return "夜深了"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Text(greeting).font(.system(size: 32, weight: .bold, design: .rounded)).foregroundStyle(Warm.ink)
                WarmDeviceCard(showLines: { showingLines = true }, addDevice: { openSettings([.add]) })
                addDeviceCard
                numbers
                if let notice { noticeBanner(notice) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .background(Warm.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingLines) { WarmLinePicker() }
    }

    private var header: some View {
        HStack {
            Text("AirSIM")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(Warm.gradient)
            Spacer()
            Button { openSettings([.help]) } label: {
                Image(systemName: "questionmark")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Warm.ink)
                    .frame(width: 46, height: 46)
                    .background(Warm.card, in: Circle())
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("帮助与诊断")
        }
        .padding(.top, 4)
    }

    private var addDeviceCard: some View {
        Button { openSettings([.add]) } label: {
            HStack(spacing: 16) {
                Circle()
                    .fill(Warm.gradient)
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: "plus").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 4) {
                    Text("添加设备").font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(Warm.ink)
                    Text("安卓手机 · voip.ms 号码 · 蓝牙直连").font(.subheadline).foregroundStyle(Warm.muted)
                }
                Spacer()
                WarmChevron(color: Warm.accent)
            }
            .padding(18)
            .background(LinearGradient(colors: [Warm.card, Warm.accentSoft], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Warm.accent.opacity(0.35), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var numbers: some View {
        let lines = model.warmLines
        let current = model.warmCurrentLine
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("我的号码").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(Warm.ink)
                Spacer()
                if !lines.isEmpty {
                    Button("全部") { showingLines = true }
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Warm.accent)
                }
            }
            .padding(.top, 6)
            VStack(spacing: 0) {
                if lines.isEmpty {
                    WarmEmptyState(title: "还没有号码", systemImage: "simcard", detail: "添加设备后，这里会列出它的每一张 SIM 卡和 voip.ms 号码")
                }
                ForEach(Array(lines.prefix(4).enumerated()), id: \.element.id) { index, line in
                    Button { model.warmSelect(line) } label: { WarmLineRow(line: line, isCurrent: line == current) }
                        .buttonStyle(.plain)
                    if index < min(lines.count, 4) - 1 { Divider().padding(.leading, 80) }
                }
                if lines.count > 4 {
                    Button("全部 \(lines.count) 个号码") { showingLines = true }
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Warm.accent)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
            }
            .warmCard(22)
        }
    }

    private struct Notice { let text: String; let action: () -> Void }

    private var notice: Notice? {
        if !model.unseenMissedCallIDs.isEmpty {
            return Notice(text: "有 \(model.unseenMissedCallIDs.count) 个未接来电") { openTab(.recents) }
        }
        if let agent = model.currentAndroidAgent, !agent.isReachable {
            return Notice(text: "\(agent.deviceName) 目前离线，来电和短信可能收不到") { openSettings([.status]) }
        }
        if !model.unreadMessageIDs.isEmpty {
            return Notice(text: "有 \(model.unreadMessageIDs.count) 条未读短信") { openTab(.messages) }
        }
        return nil
    }

    private func noticeBanner(_ notice: Notice) -> some View {
        Button(action: notice.action) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 22))
                Text(notice.text).font(.system(size: 17, weight: .medium, design: .rounded)).multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Warm.noticeText)
            .padding(18)
            .background(Warm.noticeBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct WarmDeviceCard: View {
    @EnvironmentObject private var model: AppModel
    let showLines: () -> Void
    let addDevice: () -> Void

    var body: some View {
        let agent = model.currentAndroidAgent
        let line = model.warmCurrentLine
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("当前设备").font(.system(size: 16, weight: .medium, design: .rounded)).foregroundStyle(Warm.muted)
                Spacer()
                if let agent {
                    WarmStatusDot(online: agent.isReachable)
                    Text("· \(agent.routeTitle)").font(.subheadline).foregroundStyle(Warm.muted)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent?.deviceName ?? "未配对")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Warm.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    if let line {
                        Text(line.title).font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Warm.muted)
                    }
                }
                Spacer(minLength: 8)
                if agent == nil {
                    Button("添加", action: addDevice).buttonStyle(WarmPrimaryButtonStyle())
                } else {
                    Button("切换", action: showLines).buttonStyle(WarmPrimaryButtonStyle())
                }
            }
            if let hint { Text(hint).font(.system(size: 15, design: .rounded)).foregroundStyle(hintIsWarning ? Warm.noticeText : Warm.muted) }
        }
        .padding(22)
        .warmCard(24)
    }

    private var hintIsWarning: Bool { !(model.currentAndroidAgent?.isReachable ?? false) }

    private var hint: String? {
        guard let agent = model.currentAndroidAgent else { return "配对一台安卓手机或接入 voip.ms 号码即可开始使用" }
        var parts: [String] = []
        if let battery = model.androidBattery(for: agent.id) {
            parts.append("电量 \(battery.percent)%\(battery.charging ? " · 充电中" : "")")
        }
        let count = model.simSlots(for: agent.id).count
        if count > 0 { parts.append("\(count) 条线路") }
        parts.append(agent.agentKindTitle)
        if !agent.isReachable { return "设备离线 — 检查网络或打开安卓端 AirSIM" }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Calls

struct WarmCallsView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var segment: PhoneTab
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    private var voicemailBadge: Int {
        model.warmVoicemails.filter { model.unreadMessageIDs.contains($0.id) }.count
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Warm.title("通话")
                Spacer()
                WarmStatusDot(online: model.currentAndroidAgent?.isReachable ?? false)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            WarmSegmentedControl(selection: $segment,
                                 items: [(.dial, "拨号"), (.recents, "最近"), (.contacts, "联系人"), (.voicemail, "语音信箱")],
                                 badges: [.voicemail: voicemailBadge, .recents: model.unseenMissedCallIDs.count])
                .padding(.horizontal, 20)
            Group {
                switch segment {
                case .recents: WarmRecentsList(onCall: onCall, onMessage: onMessage)
                case .contacts: WarmContactsList(onCall: onCall, onMessage: onMessage)
                case .voicemail: WarmVoicemailList(onCall: onCall, onMessage: onMessage)
                default: WarmKeypad()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Warm.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct WarmSegmentedControl: View {
    @Binding var selection: PhoneTab
    let items: [(PhoneTab, String)]
    var badges: [PhoneTab: Int] = [:]
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { item, title in
                let selected = selection == item
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { selection = item }
                } label: {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 16, weight: selected ? .semibold : .medium, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let count = badges[item], count > 0 {
                            Text("\(min(count, 99))")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Warm.accent, in: Circle())
                        }
                    }
                    .foregroundStyle(selected ? Warm.ink : Warm.muted)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Warm.card)
                                .shadow(color: .black.opacity(0.07), radius: 6, y: 2)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(5)
        .background(Warm.track, in: Capsule())
    }
}

// MARK: Keypad

struct WarmKeypad: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    @State private var showingLines = false
    @State private var zeroWasLongPressed = false
    @State private var deleteRepeatTask: Task<Void, Never>?

    private let rows = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]

    private var canCall: Bool { !model.numberInput.isEmpty && !model.isBusy && model.canStartOutgoingCommand }

    var body: some View {
        GeometryReader { proxy in
            let keyHeight = max(52, min(80, (proxy.size.height - 250) / 4))
            VStack(spacing: 0) {
                Spacer(minLength: 4)
                Text(model.numberInput.isEmpty ? " " : model.numberInput)
                    .font(.system(size: 36, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Warm.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 24)
                    .contextMenu {
                        Button { UIPasteboard.general.string = model.numberInput } label: { Label("复制号码", systemImage: "doc.on.doc") }
                            .disabled(model.numberInput.isEmpty)
                        Button {
                            if let raw = UIPasteboard.general.string { model.numberInput = DialPadPasteSanitizer.sanitize(raw) }
                        } label: { Label("粘贴号码", systemImage: "doc.on.clipboard") }
                    }
                Text(contacts.contact(for: model.numberInput)?.name ?? " ")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Warm.accent)
                    .padding(.top, 2)
                lineChip.padding(.top, 10)
                Spacer(minLength: 8)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 0) {
                            ForEach(row, id: \.0) { digit, letters in key(digit, letters, height: keyHeight) }
                        }
                    }
                }
                .padding(.horizontal, 28)
                HStack(spacing: 0) {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    Button { Task { await model.dial() } } label: {
                        Circle()
                            .fill(Warm.gradient)
                            .frame(width: 78, height: 78)
                            .shadow(color: Warm.accent.opacity(0.4), radius: 18, x: 0, y: 8)
                            .overlay(Image(systemName: "phone.fill").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCall)
                    .opacity(model.numberInput.isEmpty ? 0.55 : (canCall ? 1 : 0.45))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("拨打")
                    deleteKey.frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                Spacer(minLength: 10)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .sheet(isPresented: $showingLines) { WarmLinePicker(title: "拨号线路") }
        .onDisappear { deleteRepeatTask?.cancel(); deleteRepeatTask = nil }
    }

    private var lineChip: some View {
        Button { showingLines = true } label: {
            HStack(spacing: 8) {
                WarmRegionBadge(number: model.warmCurrentLine?.number, size: 28)
                Text(model.warmCurrentLine.map { "使用 \($0.title) 拨打" } ?? "选择拨号线路")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Warm.ink.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Warm.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("warm.dial.line")
    }

    private func key(_ digit: String, _ letters: String, height: CGFloat) -> some View {
        Button {
            guard !(digit == "0" && zeroWasLongPressed) else { zeroWasLongPressed = false; return }
            model.numberInput.append(digit)
        } label: {
            VStack(spacing: 1) {
                Text(digit).font(.system(size: 34, weight: .medium, design: .rounded)).foregroundStyle(Warm.ink)
                Text(letters.isEmpty ? " " : letters)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(Warm.muted)
            }
            .frame(maxWidth: .infinity, minHeight: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(DialToneButtonStyle(digit: digit, enabled: !model.isMuted && !model.callLifecycleSnapshot.state.representsCall))
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            if digit == "0" { zeroWasLongPressed = true; model.numberInput.append("+") }
        })
        .accessibilityLabel(letters.isEmpty ? digit : "\(digit) \(letters)")
    }

    private var deleteKey: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(Warm.muted)
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
            .opacity(model.numberInput.isEmpty ? 0 : 1)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in beginDeleting() }
                .onEnded { _ in deleteRepeatTask?.cancel(); deleteRepeatTask = nil })
            .allowsHitTesting(!model.numberInput.isEmpty)
            .accessibilityLabel(L10n.t("删除"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { deleteLast() }
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

// MARK: Recents

struct WarmRecentsList: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    private var sections: [(day: Date, records: [CallRecord])] {
        Dictionary(grouping: model.callHistory) { Calendar.current.startOfDay(for: $0.startedAt) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.startedAt > $1.startedAt }) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if model.callHistory.isEmpty {
                    WarmEmptyState(title: "暂无通话记录", systemImage: "phone.arrow.up.right")
                }
                ForEach(sections, id: \.day) { section in
                    Text(WarmDate.monthDay(section.day))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(Warm.muted)
                        .padding(.top, 8)
                        .padding(.leading, 6)
                    VStack(spacing: 0) {
                        ForEach(Array(section.records.enumerated()), id: \.element.id) { index, call in
                            WarmRecentRow(call: call, hasVoicemail: hasVoicemail(call), onCall: onCall, onMessage: onMessage)
                            if index < section.records.count - 1 { Divider().padding(.leading, 56) }
                        }
                    }
                    .warmCard(20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .refreshable { await model.refreshCallHistory() }
        .onAppear { model.markMissedCallsSeen() }
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
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    private var incoming: Bool { call.direction == "incoming" }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: incoming ? "arrow.down.left" : "arrow.up.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(call.missed ? Warm.missed : incoming ? Warm.accent : Warm.outgoing)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(WarmPhone.name(call.number, contacts: contacts))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(call.missed ? Warm.missed : Warm.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let line = WarmLineLabel.forCall(call) {
                    Text((incoming ? "打到 " : "经由 ") + line)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Warm.accent)
                        .lineLimit(1)
                }
                Text(detail).font(.system(size: 15, design: .rounded)).foregroundStyle(Warm.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let number = RecentCallDialPolicy.numberToDial(call.number) {
                Button { onMessage(number) } label: {
                    Image(systemName: "message").font(.system(size: 19)).foregroundStyle(Warm.ink.opacity(0.7)).frame(width: 40, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("发短信")
                Button { onCall(number) } label: {
                    Image(systemName: "phone.fill").font(.system(size: 19)).foregroundStyle(Warm.accent).frame(width: 40, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("回拨")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            if let number = call.number {
                Button { UIPasteboard.general.string = number } label: { Label("复制号码", systemImage: "doc.on.doc") }
            }
            Button(role: .destructive) { model.deleteCallHistory(ids: [call.id]) } label: { Label("删除记录", systemImage: "trash") }
        }
    }

    private var detail: String {
        var parts = [call.missed ? (hasVoicemail ? "未接 · 有语音留言" : "未接") : incoming ? "呼入" : "呼出",
                     call.startedAt.formatted(date: .omitted, time: .shortened)]
        if let duration = call.connectedDuration { parts.append(WarmDate.duration(duration)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Contacts

struct WarmContactsList: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    @Environment(\.openURL) private var openURL
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    @State private var search = ""

    private var filtered: [ContactStore.Contact] {
        let list = contacts.contacts.filter { !$0.phones.isEmpty }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.phones.contains { $0.contains(query) } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !contacts.isAuthorized {
                    VStack(spacing: 14) {
                        WarmEmptyState(title: contacts.authorizationState == .denied ? "通讯录权限已关闭" : "允许访问通讯录",
                                       systemImage: "person.crop.circle.badge.questionmark",
                                       detail: "用于显示来电和短信的联系人姓名")
                        Button(contacts.authorizationState == .denied ? "前往系统设置" : "允许访问") {
                            if contacts.authorizationState == .denied {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            } else {
                                Task { await contacts.requestAccessAndLoad() }
                            }
                        }
                        .buttonStyle(WarmPrimaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Warm.muted)
                        TextField("搜索姓名或号码", text: $search).textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .warmCard(16)
                    if filtered.isEmpty {
                        WarmEmptyState(title: search.isEmpty ? "通讯录为空" : "未找到联系人", systemImage: "person.2")
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, contact in
                                WarmContactRow(contact: contact, onCall: onCall, onMessage: onMessage)
                                if index < filtered.count - 1 { Divider().padding(.leading, 74) }
                            }
                        }
                        .warmCard(20)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .task { await contacts.loadIfAuthorized() }
    }
}

private struct WarmContactRow: View {
    let contact: ContactStore.Contact
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            InitialAvatar(name: contact.name, photoData: contact.photoData, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.name).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Warm.ink).lineLimit(1)
                if let phone = contact.phones.first {
                    Text(WarmPhone.format(phone) + (contact.phones.count > 1 ? " 等 \(contact.phones.count) 个号码" : ""))
                        .font(.subheadline).foregroundStyle(Warm.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let phone = contact.phones.first {
                Menu {
                    ForEach(contact.phones, id: \.self) { number in
                        Button { onMessage(number) } label: { Label(WarmPhone.format(number), systemImage: "message") }
                    }
                } label: {
                    Image(systemName: "message").font(.system(size: 19)).foregroundStyle(Warm.ink.opacity(0.7)).frame(width: 40, height: 44)
                } primaryAction: { onMessage(phone) }
                Menu {
                    ForEach(contact.phones, id: \.self) { number in
                        Button { onCall(number) } label: { Label(WarmPhone.format(number), systemImage: "phone") }
                    }
                } label: {
                    Image(systemName: "phone.fill").font(.system(size: 19)).foregroundStyle(Warm.accent).frame(width: 40, height: 44)
                } primaryAction: { onCall(phone) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: Voicemail

struct WarmVoicemailList: View {
    @EnvironmentObject private var model: AppModel
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    @State private var confirmingClear = false

    var body: some View {
        let voicemails = model.warmVoicemails
        ScrollView {
            VStack(spacing: 12) {
                if voicemails.isEmpty {
                    WarmEmptyState(title: "暂无语音留言", systemImage: "recordingtape",
                                   detail: "voip.ms 号码的来电 22 秒未接或被拒接时，会自动转入语音信箱")
                }
                ForEach(voicemails) { message in
                    WarmVoicemailRow(message: message, onCall: onCall, onMessage: onMessage)
                }
                if !voicemails.isEmpty {
                    Button("清空全部语音留言") { confirmingClear = true }
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(Warm.muted)
                        .padding(.top, 14)
                    Text("语音留言保存在这台 iPhone 上，清空后无法恢复。")
                        .font(.footnote).foregroundStyle(Warm.muted.opacity(0.8))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .confirmationDialog("清空全部语音留言？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空 \(voicemails.count) 条", role: .destructive) {
                SMSAudioPlayback.shared.stop()
                model.deleteMessages(ids: Set(voicemails.map(\.id)))
            }
        }
    }
}

private struct WarmVoicemailRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let message: SMSMessage
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    @State private var tick = 0
    @State private var loading = false

    private var audio: SMSAttachment? { message.attachments?.first { $0.kind == .audio } }
    private var playing: Bool { _ = tick; return SMSAudioPlayback.shared.isPlaying(message.id) }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    Circle()
                        .fill(Warm.soft)
                        .frame(width: 50, height: 50)
                        .overlay {
                            if loading {
                                ProgressView().tint(Warm.accent)
                            } else {
                                Image(systemName: playing ? "pause.fill" : "play.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(Warm.accent)
                                    .offset(x: playing ? 0 : 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? "暂停" : "播放语音留言")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        if model.unreadMessageIDs.contains(message.id) {
                            Circle().fill(Warm.accent).frame(width: 9, height: 9)
                        }
                        Text(WarmPhone.name(message.sender, contacts: contacts))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Warm.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    if let line = WarmLineLabel.forMessage(message) {
                        Text("打到 " + line).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(Warm.accent)
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    Text([WarmDate.dayAndTime(message.timestamp), audio?.durationLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 15, design: .rounded)).foregroundStyle(Warm.muted)
                }
                Spacer(minLength: 4)
                Button { onCall(message.sender) } label: {
                    Image(systemName: "phone").font(.system(size: 18)).foregroundStyle(Warm.ink.opacity(0.75)).frame(width: 34, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("回拨")
                Button { onMessage(message.sender) } label: {
                    Image(systemName: "message").font(.system(size: 18)).foregroundStyle(Warm.ink.opacity(0.75)).frame(width: 34, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("发短信")
            }
            if playing {
                ProgressView(value: SMSAudioPlayback.shared.progress).tint(Warm.accent)
            }
        }
        .padding(16)
        .warmCard(22)
        .onReceive(NotificationCenter.default.publisher(for: SMSAudioPlayback.didChange)) { _ in tick &+= 1 }
        .contextMenu {
            Button(role: .destructive) { model.deleteMessages(ids: [message.id]) } label: { Label("删除留言", systemImage: "trash") }
        }
    }

    private func toggle() {
        guard let audio else { return }
        if playing { SMSAudioPlayback.shared.stop(); return }
        loading = true
        Task { @MainActor in
            defer { loading = false }
            guard let file = try? await SMSMediaStore.shared.file(for: audio) else {
                model.errorMessage = "语音留言下载失败，请检查网络"
                return
            }
            SMSAudioPlayback.shared.toggle(key: message.id, file: file)
            model.markMessagesRead([message])
        }
    }
}

// MARK: - Messages

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
                let shown = sorted.last { !$0.isOutgoing }?.sender ?? sorted.last?.sender ?? ""
                return (shown, sorted)
            }
            .filter { sender, messages in
                PhoneContentSearch.smsMatches(sender: sender, contactName: contacts.contact(for: sender)?.name,
                                              messages: messages, query: search)
            }
            .sorted { ($0.messages.last?.timestamp ?? .distantPast) > ($1.messages.last?.timestamp ?? .distantPast) }
    }

    var body: some View {
        let list = conversations
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Warm.title("短信").padding(.top, 8)
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(Warm.muted)
                        TextField("搜索姓名、号码或短信内容", text: $search)
                            .font(.system(size: 17, design: .rounded))
                            .textInputAutocapitalization(.never)
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Warm.muted) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 54)
                    .warmCard(18)
                    if list.isEmpty {
                        WarmEmptyState(title: search.isEmpty ? "暂无短信" : "未找到匹配的短信", systemImage: "message")
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(list, id: \.sender) { conversation in
                                WarmConversationRow(sender: conversation.sender, messages: conversation.messages) { open(conversation.sender) }
                                Divider()
                            }
                        }
                        if search.isEmpty {
                            Button("清空全部短信") { confirmingClear = true }
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundStyle(Warm.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 18)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 100)
            }
            .refreshable { await model.loadMessagesFromAgent() }
            Button { showingComposer = true } label: {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Warm.gradient)
                    .frame(width: 66, height: 66)
                    .shadow(color: Warm.accent.opacity(0.4), radius: 14, x: 0, y: 6)
                    .overlay(Image(systemName: "pencil").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
            .padding(.bottom, 14)
            .accessibilityLabel("写短信")
        }
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
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("清空全部短信？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("删除全部", role: .destructive) { model.deleteMessages(ids: Set(model.messages.map(\.id))) }
        } message: {
            Text("只删除这台 iPhone 上 AirSIM 里的记录，不影响安卓手机和 voip.ms。")
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
        let contact = contacts.contact(for: sender)
        Button(action: open) {
            HStack(alignment: .top, spacing: 14) {
                InitialAvatar(name: contact?.name ?? avatarText, photoData: contact?.photoData,
                              fallbackContent: contact == nil && WarmPhone.digits(sender).count >= 7 ? .person : nil, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(contact?.name ?? WarmPhone.format(sender))
                            .font(.system(size: 18, weight: unread ? .bold : .semibold, design: .rounded))
                            .foregroundStyle(Warm.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let latest {
                            Text(WarmDate.short(latest.timestamp)).font(.system(size: 15, design: .rounded)).foregroundStyle(Warm.muted)
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Text(preview(latest))
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(unread ? Warm.ink.opacity(0.8) : Warm.muted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if unread { Circle().fill(Warm.accent).frame(width: 10, height: 10).padding(.top, 5) }
                    }
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { model.deleteMessages(ids: Set(messages.map(\.id))) } label: { Label("删除会话", systemImage: "trash") }
        }
    }

    /// Short codes and names get their first characters as the avatar text.
    private var avatarText: String {
        let digits = WarmPhone.digits(sender)
        return digits.count >= 7 ? "#" : String(sender.prefix(2))
    }

    private func preview(_ message: SMSMessage?) -> String {
        guard let message else { return "" }
        var body = message.content
        if message.isOutgoing { body = "我：" + body }
        guard let line = WarmLineLabel.forMessage(message) else { return body }
        return "经 \(line) · \(body)"
    }
}

// MARK: - Account

struct WarmAccountView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let openSettings: ([AirSIMSettingsPage]) -> Void
    let openTab: (PhoneTab) -> Void
    @State private var showingLines = false

    private var relayHost: String {
        let url = RelayConfiguration.effectiveURL(
            stored: UserDefaults.standard.string(forKey: "airsim.push-relay-url"),
            buildSetting: Bundle.main.object(forInfoDictionaryKey: "AirSIMPushRelayURL") as? String,
            bundleID: Bundle.main.bundleIdentifier)
        return URL(string: url)?.host ?? url
    }

    var body: some View {
        let agents = model.pairedAndroidAgents
        let online = agents.filter(\.isReachable).count
        let lines = model.warmLines
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Warm.title("我的").padding(.top, 8)
                profile
                HStack(spacing: 14) {
                    tile(title: "设备", value: "\(agents.count)", detail: "\(online) 台在线", highlighted: true) { openSettings([.connections]) }
                    tile(title: "号码", value: "\(lines.count)", detail: "条线路", highlighted: false) { showingLines = true }
                }
                section("通用")
                VStack(spacing: 0) {
                    row("person.text.rectangle", "默认线路", model.warmCurrentLine?.title ?? "未选择") { showingLines = true }
                    divider
                    row("antenna.radiowaves.left.and.right", "连接与设备", "\(agents.count) 台设备 · 配对与连接方式") { openSettings([.connections]) }
                    divider
                    row("phone.bubble", "来电与短信", "来电通知、短信与转发") { openSettings([.calls]) }
                    divider
                    row("paintpalette", "外观与主题", "当前：\(settings.theme.title)") { openSettings([.preferences]) }
                    divider
                    row("dot.radiowaves.left.and.right", "连接状态", (model.currentAndroidAgent?.isReachable ?? false) ? "在线 · \(model.currentAndroidAgent?.routeTitle ?? "")" : "离线",
                        trailing: AnyView(Circle().fill((model.currentAndroidAgent?.isReachable ?? false) ? Warm.online : Warm.muted.opacity(0.5)).frame(width: 12, height: 12))) {
                        openSettings([.status])
                    }
                }
                .warmCard(22)
                section("支持")
                VStack(spacing: 0) {
                    row("stethoscope", "帮助与诊断", "检查本地、蓝牙与云端链路") { openSettings([.help]) }
                    divider
                    row("bubble.left.and.text.bubble.right", "意见反馈", "附带日志，帮助定位问题") { openSettings([.feedback]) }
                    divider
                    row("info.circle", "关于 AirSIM", "版本 \(AppInformation.version)") { openSettings([.about]) }
                    divider
                    row("gearshape", "全部设置", "所有高级选项") { openSettings([]) }
                }
                .warmCard(22)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Warm.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingLines) { WarmLinePicker(title: "默认线路") }
    }

    private var profile: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(Warm.accentSoft)
                .frame(width: 72, height: 72)
                .overlay(Text("AS").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(Warm.accent))
            VStack(alignment: .leading, spacing: 4) {
                Text("AirSIM").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(Warm.ink)
                Text(relayHost).font(.subheadline).foregroundStyle(Warm.muted).lineLimit(1)
                Text("版本 \(AppInformation.version)").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Warm.accent)
            }
            Spacer()
        }
        .padding(20)
        .warmCard(24)
    }

    private func tile(title: String, value: String, detail: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).tracking(2).foregroundStyle(Warm.muted)
                Text(value).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Warm.ink)
                HStack(spacing: 4) {
                    Text(detail).font(.system(size: 16, weight: .semibold, design: .rounded))
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(highlighted ? Warm.accent : Warm.ink.opacity(0.75))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background {
                let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
                if highlighted {
                    shape.fill(LinearGradient(colors: [Warm.accentSoft, Warm.card], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(shape.strokeBorder(Warm.accent.opacity(0.7), lineWidth: 1.5))
                } else {
                    shape.fill(Warm.card).overlay(shape.strokeBorder(Warm.border, lineWidth: 1))
                        .shadow(color: .black.opacity(0.045), radius: 12, y: 4)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).tracking(2).foregroundStyle(Warm.muted)
            .padding(.leading, 6).padding(.top, 6)
    }

    private var divider: some View { Divider().padding(.leading, 76) }

    private func row(_ icon: String, _ title: String, _ subtitle: String, trailing: AnyView? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Circle()
                    .fill(Warm.soft)
                    .frame(width: 46, height: 46)
                    .overlay(Image(systemName: icon).font(.system(size: 19, weight: .medium)).foregroundStyle(Warm.accent))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(Warm.ink)
                    Text(subtitle).font(.subheadline).foregroundStyle(Warm.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let trailing { trailing } else { WarmChevron() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
