#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Simulator-only UI-test data. Never compiled into device or Release binaries.
/// Uses temporary history and process-local preference overrides, not paired data.
@MainActor
struct SMSNavigationFixture {
    let model: AppModel
    let updates: AppUpdateController
    let defaults: UserDefaults

    private static let previewStartedAt = Date()

    static var previewCall: CallRecord? {
        guard let phase = ProcessInfo.processInfo.environment["AIRSIM_UI_CALL"],
              ["incoming", "active"].contains(phase) else { return nil }
        return CallRecord(id: "layout-preview", index: 0, direction: "incoming", state: phase,
            number: ProcessInfo.processInfo.environment["AIRSIM_UI_REGION_NUMBER"] ?? (ProcessInfo.processInfo.environment["AIRSIM_UI_REGION"] == "1" ? "+86 138 0013 8000" : "+86 138 0000 0000"),
            startedAt: previewStartedAt, updatedAt: previewStartedAt, endedAt: nil, missed: false,
            slotIndex: ProcessInfo.processInfo.environment["AIRSIM_UI_REGION"] == "1" ? 1 : nil)
    }

    static func fromLaunchEnvironment() -> Self? {
        guard ProcessInfo.processInfo.environment["AIRSIM_UI_FIXTURE"] == "sms-navigation" else { return nil }
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        // The unit-test host also uses this inert root view. Its routing tests
        // must be able to write preferences; reserve UI overrides for UI runners.
        if NSClassFromString("XCTestCase") == nil {
            arguments[ConnectionModePreference.key] = AirSIMConnectionMode.bluetooth.rawValue
            arguments[CloudSignalingPreference.key] = false
            // Since v0.9.8.27 saved paired devices stay listed while offline. Each UI fixture
            // starts with none, so a device another fixture launch saved cannot leak in.
            for key in ["airsim.paired-android-devices.v1", "airsim.forgotten-android-devices.v1"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if ProcessInfo.processInfo.environment["AIRSIM_UI_SMS_SIM"] == "1" {
            let agentID = "sms-sim-fixture"
            arguments[AndroidAgentBindingPreference.key] = agentID
            let slots = try! JSONDecoder().decode([AndroidSIMSlot].self, from: Data("""
            [{"id":"fixture-1","label":"SIM 1","slot_index":0},
             {"id":"fixture-2","label":"SIM 2","slot_index":1,"is_default_sms":true}]
            """.utf8))
            SMSSIMPreference.forget(agentID: agentID)
            SMSSIMPreference.remember(agentID: agentID, slots: slots)
        }
        let withLines = ProcessInfo.processInfo.environment["AIRSIM_UI_LINES"] == "1"
        if withLines, NSClassFromString("XCTestCase") == nil {
            // Shell screenshots with a realistic roster: 家中 K40 (one SIM) + voip.ms (two DIDs), all online.
            // The cloud status comes from `linesStatus` below; nothing reaches a Relay.
            arguments[ConnectionModePreference.key] = AirSIMConnectionMode.cloud.rawValue
            arguments[AndroidAgentBindingPreference.key] = "k40-fixture"
        }
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let defaults = UserDefaults(suiteName: "AirSIM.UITest.\(UUID().uuidString)")!
        defaults.set(true, forKey: "airsim.first-connection-complete")
        defaults.set(PhoneTab.messages.rawValue, forKey: "airsim.selected-tab")
        let history = LocalHistoryStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("AirSIM-UI-\(UUID().uuidString)", isDirectory: true))
        let content = ProcessInfo.processInfo.environment["AIRSIM_UI_CODE_SMS"] == "1"
            ? "【AirSIM测试】验证码：123456，5分钟内有效。请勿泄露。" : "test message"
        history.saveMessages([SMSMessage(sender: "sms-navigation-fixture", content: content,
            code: nil, timestamp: Date(timeIntervalSince1970: 1_790_000_000), deliveryID: "navigation-fixture")])
        if ProcessInfo.processInfo.environment["AIRSIM_UI_SEARCH"] == "1" {
            history.saveMessages([
                SMSMessage(sender: "2025550100", content: "pickup-token 123456", code: nil, timestamp: Date(timeIntervalSince1970: 100)),
                SMSMessage(sender: "2025550100", content: "latest-only", code: nil, timestamp: Date(timeIntervalSince1970: 200)),
                SMSMessage(sender: "3035550123", content: "travel-plan", code: nil, timestamp: Date(timeIntervalSince1970: 300))])
        }
        if ProcessInfo.processInfo.environment["AIRSIM_UI_WARM"] == "1" {
            // 暖橙 shell screenshots: voip.ms-style lines, an MMS, a voicemail and line-tagged calls.
            let agent = "voipms-fixture", now = Date()
            SIMLineDisplay.update(agentID: agent, slots: try! JSONDecoder().decode([AndroidSIMSlot].self, from: Data("""
            [{"id":"voipms:2365550777","label":"voip.ms","number":"+12365550777","slot_index":0},
             {"id":"voipms:6725550111","label":"voip.ms","number":"+16725550111","slot_index":1}]
            """.utf8)))
            history.saveMessages([
                SMSMessage(sender: "22922", content: "Best Buy: Your verification code is 640970. It's valid for 5 minutes.",
                           code: "640970", timestamp: now.addingTimeInterval(-3_600), deliveryID: "warm-1",
                           sourceAgentID: agent, simSlot: "SIM 1"),
                SMSMessage(sender: "+17785550591", content: "语音留言 0:12", code: nil, timestamp: now.addingTimeInterval(-7_200),
                           deliveryID: "warm-vm", sourceAgentID: agent, simSlot: "SIM 2",
                           attachments: [SMSAttachment(kind: .audio, url: "https://relay.example/voipms/media/s/vm.wav", mime: "audio/wav", duration: 12)]),
                SMSMessage(sender: "10086", content: "尊敬的客户，您本月套餐剩余流量 12.3GB。", code: nil,
                           timestamp: now.addingTimeInterval(-10_800), deliveryID: "warm-10086", sourceAgentID: agent, simSlot: "SIM 1"),
                SMSMessage(sender: "95588", content: "您尾号 0000 的工行账户 11月20日 收入 100.00 元。", code: nil,
                           timestamp: now.addingTimeInterval(-14_400), deliveryID: "warm-95588", sourceAgentID: agent, simSlot: "SIM 1"),
                SMSMessage(sender: "+16045550100", content: "[图片]", code: nil, timestamp: now.addingTimeInterval(-90_000),
                           deliveryID: "warm-mms", sourceAgentID: agent, simSlot: "SIM 2",
                           attachments: [SMSAttachment(kind: .image, url: "https://relay.example/voipms/media/s/a.jpg", mime: "image/jpeg")]),
            ])
            let calls = [
                CallRecord(id: "warm-c1", index: 0, direction: "outgoing", state: "ended", number: "+17785550591",
                           startedAt: now.addingTimeInterval(-1_800), updatedAt: now, endedAt: now.addingTimeInterval(-1_779),
                           missed: false, connectedAt: now.addingTimeInterval(-1_800), sourceAgentID: agent, slotIndex: 1),
                CallRecord(id: "warm-c2", index: 0, direction: "incoming", state: "ended", number: "+17785550591",
                           startedAt: now.addingTimeInterval(-7_205), updatedAt: now, endedAt: now.addingTimeInterval(-7_190),
                           missed: true, sourceAgentID: agent, slotIndex: 1),
                CallRecord(id: "warm-c3", index: 0, direction: "incoming", state: "ended", number: "+14375550937",
                           startedAt: now.addingTimeInterval(-95_000), updatedAt: now, endedAt: now.addingTimeInterval(-94_900),
                           missed: false, connectedAt: now.addingTimeInterval(-95_000), sourceAgentID: agent, slotIndex: 0),
            ]
            history.saveCallHistory(calls)
        }
        let contactCache = ContactCacheStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("AirSIM-UI-contacts-\(UUID().uuidString).json"))
        let model = withLines
            ? AppModel(contactStore: ContactStore(fetcher: NavigationContactFetcher(), cache: contactCache),
                       historyStore: history, cloudStatusFetcher: { linesStatus })
            : AppModel(contactStore: ContactStore(fetcher: NavigationContactFetcher(), cache: contactCache),
                       historyStore: history)
        model.messages = history.loadMessages()
        if withLines { Task { @MainActor in await model.refreshCloudStatusForDiagnostics() } }
        if ProcessInfo.processInfo.environment["AIRSIM_UI_RECENTS"] == "1" {
            let now = Date()
            var calls = [CallRecord(id: "recent-a", index: 0, direction: "incoming", state: "ended", number: "13800138000", startedAt: now, updatedAt: now, endedAt: now, missed: true),
                CallRecord(id: "recent-b", index: 0, direction: "outgoing", state: "ended", number: "+86 138 0013 8000", startedAt: now.addingTimeInterval(-600), updatedAt: now, endedAt: now, missed: false)]
            if ProcessInfo.processInfo.environment["AIRSIM_UI_RECENTS_LONG_REGION"] == "1" {
                calls.append(CallRecord(id: "recent-long", index: 0, direction: "incoming", state: "ended",
                    number: "18844737195", startedAt: now.addingTimeInterval(-300), updatedAt: now,
                    endedAt: now, missed: false))
            }
            history.saveCallHistory(calls); model.callHistory = calls
            if ProcessInfo.processInfo.environment["AIRSIM_UI_LATE_MISSED"] == "1" {
                // A cloud line's record lands seconds after Recents is already on screen.
                let earlier = calls
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(10))
                    let late = CallRecord(id: "recent-late", index: 0, direction: "incoming", state: "ended",
                        number: "16045550188", startedAt: Date(), updatedAt: Date(), endedAt: Date(), missed: true)
                    history.saveCallHistory([late] + earlier); model.callHistory = [late] + earlier
                }
            }
        }
        if ProcessInfo.processInfo.environment["AIRSIM_UI_WARM"] == "1" { model.callHistory = history.loadCallHistory() }
        let updates = AppUpdateController(defaults: defaults, fetch: { [] })
        updates.acknowledgeNotes()
        return Self(model: model, updates: updates, defaults: defaults)
    }
}

/// AIRSIM_UI_LINES roster. Numbers are fictional (555-01xx / masked mainland range).
@MainActor private var linesStatus: CloudAgentStatus {
    let now = Date().timeIntervalSince1970 * 1000
    return try! JSONDecoder().decode(CloudAgentStatus.self, from: Data("""
    {"cloud_online":true,"active_agent_id":"k40-fixture","agents":[
     {"agent_id":"k40-fixture","device_name":"家中 K40","cloud_online":true,
      "battery":{"percent":82,"charging":false,"observed_at_ms":\(now)},
      "sim_slots":[{"id":"k40-1","label":"SIM 1","slot_index":0,"carrier_name":"中国电信","number":"+8613800000426",
                    "default":true,"signal":{"level":3,"observed_at_ms":\(now)}}]},
     {"agent_id":"voipms-fixture","agent_kind":"voipms","device_name":"voip.ms","cloud_online":true,
      "sim_slots":[{"id":"voipms:2365550777","label":"voip.ms","number":"+12365550777","slot_index":0,"signal":{"level":4,"observed_at_ms":\(now)}},
                   {"id":"voipms:6725550111","label":"voip.ms","number":"+16725550111","slot_index":1,"signal":{"level":4,"observed_at_ms":\(now)}}]}]}
    """.utf8))
}

private struct NavigationContactFetcher: ContactFetching {
    func authorizationState() -> ContactAuthorizationState { .authorized }
    func requestAccess() async throws -> Bool { true }
    func fetchAll() throws -> [ContactStore.Contact] {
        var all: [ContactStore.Contact] = [.init(id: "navigation-contact", name: "Navigation Alice", phones: ["2025550100"], emails: [], photoData: nil)]
        if ProcessInfo.processInfo.environment["AIRSIM_UI_LINES"] == "1" {
            all += [.init(id: "c-lin", name: "林青", phones: ["+17785550591"], emails: [], photoData: nil),
                    .init(id: "c-zhou", name: "周宁", phones: ["+16045550142", "+8613800000188"], emails: [], photoData: nil),
                    .init(id: "c-chen", name: "陈岚", phones: ["+14375550937"], emails: [], photoData: nil)]
        }
        return all
    }
}
#endif
