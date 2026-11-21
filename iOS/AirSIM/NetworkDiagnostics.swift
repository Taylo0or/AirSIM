import Network
import SwiftUI
import UIKit
import UserNotifications

// In-app network diagnostics (settings › 帮助与诊断 › 网络诊断).
//
// Idea taken from 2020cqyd's PR (unified "诊断与修复"), rebuilt on this fork's own APIs:
// the PR version depends on its network-recovery module and new Android endpoints that
// this branch does not carry. Everything here is read-only except the explicit repair button.

/// Result of timing `GET /healthz` on the Relay (no credentials are sent).
struct RelayProbeResult: Equatable, Sendable {
    let host: String
    let version: String
    let millis: [Int]
    let failures: Int

    var median: Int? {
        guard !millis.isEmpty else { return nil }
        let sorted = millis.sorted()
        return sorted[sorted.count / 2]
    }
}

/// Last push receipts as seen by the app. Only times are kept, never content.
enum NetworkDiagnosticsStore {
    private static let voipKey = "airsim.diag.last-voip-push"
    private static let smsKey = "airsim.diag.last-sms-push"
    private static let smsDelayKey = "airsim.diag.last-sms-delay"

    static func recordVoIPPush(at date: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: voipKey)
    }

    /// `sentAt` is the Android/voip.ms receive time carried by the push.
    static func recordSMSPush(sentAt: Date, at date: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: smsKey)
        defaults.set(date.timeIntervalSince(sentAt), forKey: smsDelayKey)
    }

    static func lastVoIPPush(defaults: UserDefaults = .standard) -> Date? {
        date(defaults.double(forKey: voipKey))
    }

    static func lastSMSPush(defaults: UserDefaults = .standard) -> (receivedAt: Date, delay: TimeInterval)? {
        guard let received = date(defaults.double(forKey: smsKey)) else { return nil }
        return (received, defaults.double(forKey: smsDelayKey))
    }

    private static func date(_ seconds: Double) -> Date? {
        seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }
}

/// The iPhone's own network path, summarised for people.
struct LocalNetworkSnapshot: Equatable, Sendable {
    var satisfied: Bool
    var primary: String
    var others: [String]
    var vpn: Bool
    var expensive: Bool
    var constrained: Bool

    static func describe(_ path: NWPath) -> LocalNetworkSnapshot {
        let names = path.availableInterfaces.map(label)
        // A VPN puts its tunnel first in the path's interface order.
        let vpn = path.availableInterfaces.first.map(isTunnel) ?? false
        return LocalNetworkSnapshot(
            satisfied: path.status == .satisfied,
            primary: names.first ?? "无",
            others: Array(names.dropFirst()),
            vpn: vpn,
            expensive: path.isExpensive,
            constrained: path.isConstrained)
    }

    static func isTunnel(_ interface: NWInterface) -> Bool {
        interface.type == .other && ["utun", "ipsec", "ppp", "tun"].contains { interface.name.hasPrefix($0) }
    }

    static func label(_ interface: NWInterface) -> String {
        if isTunnel(interface) { return "VPN 隧道" }
        switch interface.type {
        case .wifi: return "Wi-Fi"
        case .cellular: return "蜂窝数据"
        case .wiredEthernet: return "有线网络"
        case .loopback: return "本机回环"
        default: return "其他（\(interface.name)）"
        }
    }

    /// One-shot read of the current path.
    static func current() async -> LocalNetworkSnapshot {
        /// The handler only runs on `queue`, so the flag needs no further locking.
        final class Once: @unchecked Sendable { var done = false }
        return await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "airsim.network-diagnostics")
            let once = Once()
            monitor.pathUpdateHandler = { path in
                guard !once.done else { return }
                once.done = true
                monitor.cancel()
                continuation.resume(returning: describe(path))
            }
            monitor.start(queue: queue)
        }
    }
}

enum NetworkDiagnosticsCopy {
    static func latency(_ result: RelayProbeResult) -> String {
        guard let median = result.median else { return "全部失败" }
        let samples = result.millis.map(String.init).joined(separator: " / ")
        let failed = result.failures > 0 ? "，失败 \(result.failures) 次" : ""
        return "\(median) ms（\(samples) ms\(failed)）"
    }

    static func delay(_ seconds: TimeInterval) -> String {
        if seconds < 0 { return "时钟偏差，无法估算" }
        if seconds < 1 { return "不到 1 秒" }
        if seconds < 120 { return String(format: "约 %.0f 秒", seconds) }
        return String(format: "约 %.0f 分钟", seconds / 60)
    }

    static func permission(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已允许"
        case .provisional: return "临时授权（静默显示）"
        case .ephemeral: return "临时会话授权"
        case .denied: return "已拒绝，请到系统设置开启"
        case .notDetermined: return "尚未授权"
        @unknown default: return "未知"
        }
    }
}

/// Sections rendered inside the settings list.
struct NetworkDiagnosticsSections: View {
    @EnvironmentObject private var model: AppModel
    @State private var network: LocalNetworkSnapshot?
    @State private var relay: RelayProbeResult?
    @State private var relayError: String?
    @State private var agents: [CloudAndroidAgent] = []
    @State private var agentsError: String?
    @State private var notifications: UNNotificationSettings?
    @State private var checkedAt: Date?
    @State private var checking = false
    @State private var repairing = false
    @State private var repairResult: String?
    @State private var copied = false

    private var inCall: Bool { model.callLifecycleSnapshot.state.representsCall }
    private var relayBlocked: Bool { RelayEgressGate.shared.isBlocked }

    var body: some View {
        Group {
            Section {
                if let network {
                    LabeledContent("状态", value: network.satisfied ? "已连接" : "无网络")
                    LabeledContent("当前线路", value: network.primary)
                    if !network.others.isEmpty {
                        LabeledContent("备用", value: network.others.joined(separator: "、"))
                    }
                    if network.vpn { LabeledContent("VPN", value: "已开启（经隧道访问）") }
                    if network.constrained { LabeledContent("低数据模式", value: "已开启") }
                } else {
                    placeholder
                }
            } header: { Text("本机网络") }

            Section {
                if relayBlocked {
                    Text("纯本地模式已开启，不访问 Relay。").foregroundStyle(.secondary)
                } else if let relay {
                    LabeledContent("地址", value: relay.host)
                    LabeledContent("往返延迟", value: NetworkDiagnosticsCopy.latency(relay))
                    LabeledContent("服务版本", value: relay.version)
                } else if let relayError {
                    Label(relayError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    placeholder
                }
            } header: { Text("云端 Relay") } footer: {
                Text("计时 3 次只读健康检查，不发送账号凭据。来电推送和云端通话都经过 Relay。")
            }

            Section {
                if relayBlocked {
                    Text("纯本地模式下不查询 Relay 心跳。").foregroundStyle(.secondary)
                } else if let agentsError {
                    Label(agentsError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if agents.isEmpty {
                    if checkedAt == nil { placeholder } else { Text("Relay 上没有已登记的设备。").foregroundStyle(.secondary) }
                }
                ForEach(agents) { agent in
                    LabeledContent(name(agent)) {
                        Label(agent.cloudOnline ? "在线" : "离线",
                              systemImage: agent.cloudOnline ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(agent.cloudOnline ? Color.green : Color.orange)
                    }
                }
                if model.pairedDeviceHistory.contains(where: { !model.isCloudOnlyAgent($0.id) }) {
                    LabeledContent("安卓局域网直连", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                }
            } header: { Text("线路与设备") } footer: {
                Text("“在线”表示 Relay 最近约 150 秒收到过该设备的心跳；voip.ms 线路由服务器桥接上报。")
            }

            Section {
                LabeledContent("通知权限", value: notifications.map { NetworkDiagnosticsCopy.permission($0.authorizationStatus) } ?? "—")
                if let notifications, notifications.authorizationStatus == .authorized {
                    LabeledContent("横幅 / 声音", value: "\(notifications.alertSetting == .enabled ? "开" : "关") / \(notifications.soundSetting == .enabled ? "开" : "关")")
                }
                LabeledContent("最近来电推送", value: time(NetworkDiagnosticsStore.lastVoIPPush()))
                if let sms = NetworkDiagnosticsStore.lastSMSPush() {
                    LabeledContent("最近短信推送", value: time(sms.receivedAt))
                    LabeledContent("短信到达耗时", value: NetworkDiagnosticsCopy.delay(sms.delay))
                } else {
                    LabeledContent("最近短信推送", value: "暂无记录")
                }
            } header: { Text("推送") } footer: {
                Text("只记录 App 实际处理到的推送；App 未被唤醒时没有记录不代表推送失败。到达耗时按设备收到短信的时间计算，可能包含两端时钟偏差。")
            }

            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    Label(checking ? "正在检查…" : "重新检查", systemImage: "arrow.clockwise")
                }
                .disabled(checking)
                Button {
                    Task { await repair() }
                } label: {
                    Label(repairing ? "正在修复…" : "重新连接设备并同步短信", systemImage: "wrench.and.screwdriver")
                }
                .disabled(repairing || inCall)
                if let repairResult { Text(repairResult).font(.footnote).foregroundStyle(.secondary) }
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制诊断结果", systemImage: "doc.on.doc")
                }
                .disabled(checkedAt == nil)
            } footer: {
                Text(inCall ? "通话中只检查，不重建连接。" : "修复只重新查询已配对设备并刷新短信，不删除配对或记录。\(checkedAt.map { "上次检查 " + time($0) } ?? "")")
            }
        }
        .task { await refresh() }
    }

    private var placeholder: some View {
        HStack(spacing: 8) { ProgressView(); Text("正在检查…").foregroundStyle(.secondary) }
    }

    private func name(_ agent: CloudAndroidAgent) -> String {
        if let device = model.pairedDeviceHistory.first(where: { $0.id == agent.agentID }) { return device.deviceName }
        return agent.deviceName ?? agent.model ?? "设备 …\(agent.agentID.suffix(6))"
    }

    private func time(_ date: Date?) -> String {
        date?.formatted(.dateTime.month().day().hour().minute().second()) ?? "暂无记录"
    }

    private var report: String {
        var lines = ["AirSIM 网络诊断 \(time(checkedAt))"]
        if let network {
            lines.append("本机：\(network.satisfied ? network.primary : "无网络")\(network.vpn ? " · VPN" : "")\(network.constrained ? " · 低数据" : "")")
        }
        if relayBlocked { lines.append("Relay：纯本地模式") }
        else if let relay { lines.append("Relay：\(relay.host) v\(relay.version) \(NetworkDiagnosticsCopy.latency(relay))") }
        else if let relayError { lines.append("Relay：\(relayError)") }
        for agent in agents { lines.append("\(name(agent))：\(agent.cloudOnline ? "在线" : "离线")") }
        lines.append("局域网直连：\(VoWLANStatusCopy.text(for: model.vowlan.availability))")
        lines.append("通知：\(notifications.map { NetworkDiagnosticsCopy.permission($0.authorizationStatus) } ?? "—")")
        lines.append("最近来电推送：\(time(NetworkDiagnosticsStore.lastVoIPPush()))")
        if let sms = NetworkDiagnosticsStore.lastSMSPush() {
            lines.append("最近短信推送：\(time(sms.receivedAt))，\(NetworkDiagnosticsCopy.delay(sms.delay))")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor private func refresh() async {
        guard !checking else { return }
        checking = true
        copied = false
        defer { checking = false; checkedAt = Date() }
        async let path = LocalNetworkSnapshot.current()
        notifications = await UNUserNotificationCenter.current().notificationSettings()
        network = await path
        guard !relayBlocked else { relay = nil; agents = []; return }
        do {
            relay = try await VoIPPushController.shared.probeRelayForDiagnostics()
            relayError = nil
        } catch {
            relay = nil
            relayError = "无法访问：\(error.localizedDescription)"
        }
        do {
            agents = try await VoIPPushController.shared.fetchCloudAgentStatusForDiagnostics(allowLocalMode: true).agents
            agentsError = nil
        } catch {
            agents = []
            agentsError = "心跳查询失败：\(error.localizedDescription)"
        }
    }

    @MainActor private func repair() async {
        guard !repairing, !inCall else { return }
        repairing = true
        defer { repairing = false }
        await model.refreshPairedDeviceInformation()
        if !inCall { await model.refreshMessages(silently: true) }
        repairResult = "已重新查询设备并刷新短信（\(time(Date()))）。"
        await refresh()
    }
}
