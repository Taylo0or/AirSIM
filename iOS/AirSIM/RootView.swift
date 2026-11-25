import SwiftUI
import UIKit

enum SystemCommunicationDestination: Equatable {
    case call(String)
    case message(String)
    case liveActivity(AirSIMLiveActivityAction, callID: String)
}

enum SystemCommunicationURL {
    static func destination(for url: URL) -> SystemCommunicationDestination? {
        if let action = AirSIMLiveActivityActionURL.parse(url) {
            return .liveActivity(action.action, callID: action.callID)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "tel" || scheme == "im" else {
            return nil
        }
        let prefixLength = scheme.count + 1
        guard url.absoluteString.count > prefixLength else { return nil }
        var target = String(url.absoluteString.dropFirst(prefixLength))
        while target.hasPrefix("//") { target.removeFirst(2) }
        target = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        target = target.removingPercentEncoding ?? target
        target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return scheme == "tel" ? .call(target) : .message(target)
    }
}

/// Destinations of the app shell (首页 / 通话 segments / 短信 / 我的); raw values are persisted.
enum PhoneTab: String, CaseIterable, Identifiable {
    case home = "首页"
    case voicemail = "语音信箱"
    case dial = "拨号"
    case recents = "最近通话"
    case messages = "短信"
    case contacts = "通讯录"
    case settings = "设置"

    var id: String { rawValue }
}


/// 五个主要目的地使用系统 TabView；iOS 26 原生标签栏负责 Liquid Glass、
/// 长按放大与选中态交互，避免分页手势和自绘按钮争抢横向滑动。
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appUpdates: AppUpdateController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appUpdatePresentation: AppUpdatePresentation?
    @AppStorage("airsim.selected-tab") private var selectedTabRawValue = PhoneTab.home.rawValue
    @State private var collapsedCallID: String?
    @State private var callbackSIMRequest: CallbackSIMDialRequest?
    @State private var pendingSMSRecipient: String?
    @State private var conversationSender: String?
    @State private var showingConversation = false
    @AppStorage("airsim.first-connection-complete") private var firstConnectionComplete = false

    private var presentedCall: CallRecord? {
#if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["AIRSIM_UI_FIXTURE"] == "sms-navigation",
           let preview = SMSNavigationFixture.previewCall { return preview }
#endif
        return model.inAppPresentedCall
    }

    private func callReturnBar(_ call: CallRecord) -> some View {
        Button { collapsedCallID = nil } label: {
            HStack(spacing: 8) {
                Image(systemName: "phone.fill")
                Text("返回通话")
                Text(model.contacts.displayName(for: call.number)).monospacedDigit().lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(Color.green, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 6)
        .background(Color(uiColor: WarmPalette.background))
        .accessibilityIdentifier("call.restore")
    }

    private var callSurfaceVisible: Bool {
        guard let call = presentedCall else { return false }
        // A new incoming state must never remain hidden by an earlier collapse.
        return CallSurfaceContent(state: call.state).phase == .incoming || collapsedCallID != call.id
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // A collapsed call pushes the shell down instead of covering its page titles.
                if let call = presentedCall, !callSurfaceVisible { callReturnBar(call) }
                WarmShellView(phoneTab: tabBinding, pendingSMSRecipient: $pendingSMSRecipient,
                              conversationSender: $conversationSender, showingConversation: $showingConversation,
                              onCall: dial, onMessage: composeMessage, openConversation: showSMSConversation)
            }
                // Keep navigation state, but hide the shell from rendering, hit testing
                // and VoiceOver while the in-app call surface is on top.
                .opacity(callSurfaceVisible ? 0 : 1)
                .allowsHitTesting(!callSurfaceVisible)
                .accessibilityHidden(callSurfaceVisible)
                .tint(settings.theme.accent)

            if let call = presentedCall {
                ActiveCallView(call: call, isPresented: callSurfaceVisible,
                               onMinimize: { collapsedCallID = call.id })
                    // Keep the same call view mounted; collapse changes presentation only.
                    .opacity(callSurfaceVisible ? 1 : 0)
                    .allowsHitTesting(callSurfaceVisible)
                    .accessibilityHidden(!callSurfaceVisible)
                    .zIndex(1)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .background(PhoneBackdrop())
        .modifier(CallbackSIMDialChoice(request: $callbackSIMRequest, choose: confirmCallbackSIM))
        .onChange(of: model.callLifecycleSnapshot.state.representsCall) { inCall in
            if inCall { callbackSIMRequest = nil }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.inAppPresentedCall?.id)
        .preferredColorScheme(settings.appearance.colorScheme)
        .onChange(of: presentedCall?.id) { _ in collapsedCallID = nil }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let reminder = model.otherDeviceCallReminders.first {
                Button {
                    _ = model.openOtherDeviceCallNotification(reminder.userInfo)
                } label: {
                    Label("\(reminder.deviceName) 来电 · 其他设备 \(model.otherDeviceCallReminders.count)", systemImage: "phone.badge.waveform")
                        .font(.subheadline.weight(.semibold)).padding(12)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain).padding(.horizontal)
            }
        }
        .sheet(item: $model.focusedOtherDeviceCall, onDismiss: presentAppUpdateIfIdle) { reminder in
            OtherDeviceCallSheet(reminder: reminder).environmentObject(model)
        }
        .fullScreenCover(isPresented: Binding(
            get: { !firstConnectionComplete && !appUpdates.needsNotes && appUpdatePresentation == nil && appUpdateCallIdle },
            // Completion is written only by explicit actions in the onboarding view.
            // A call can temporarily dismiss this cover without completing pairing.
            set: { _ in }
        )) {
            AirSIMFirstConnectionView()
                .environmentObject(model)
        }
        .onOpenURL(perform: handleSystemCommunicationURL)
        .fullScreenCover(item: $appUpdatePresentation, onDismiss: presentAppUpdateIfIdle) { presentation in
            AppUpdateSheet(presentation: presentation, updates: appUpdates)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            presentAppUpdateIfIdle()
            if firstConnectionComplete && appUpdateCallIdle {
                _ = await appUpdates.check(manual: false)
                presentAppUpdateIfIdle()
            }
        }
        .onChange(of: appUpdates.needsNotes) { _ in presentAppUpdateIfIdle() }
        .onChange(of: appUpdates.pendingUpdate) { _ in presentAppUpdateIfIdle() }
        .onChange(of: selectedTabRawValue) { _ in presentAppUpdateIfIdle() }
        .onChange(of: firstConnectionComplete) { complete in
            if complete && scenePhase == .active && appUpdateCallIdle {
                Task { _ = await appUpdates.check(manual: false); presentAppUpdateIfIdle() }
            }
        }
        .onChange(of: model.inAppPresentedCall?.id) { _ in handleAppUpdateCallChange() }
        .onChange(of: model.activeCall?.id) { _ in handleAppUpdateCallChange() }
        .onChange(of: model.remoteCall?.id) { _ in handleAppUpdateCallChange() }
        .onChange(of: model.pendingOutgoingCall?.id) { _ in handleAppUpdateCallChange() }
        .onChange(of: model.errorMessage) { _ in presentAppUpdateIfIdle() }
        .onAppear {
            if let info = OtherAndroidCallPresentationRequest.consume() { _ = model.openOtherDeviceCallNotification(info) }
            if let sender = IncomingSMSPresentationRequest.consume() {
                openSMSConversation(sender)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimRemoteSMSReceived)) { _ in
            model.reloadMessagesFromLocalStore()
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimOpenSMSConversation)) { notification in
            let sender = IncomingSMSPresentationRequest.consume()
                ?? notification.userInfo?["sender"] as? String
            guard let sender else {
                selectedTab = .messages
                return
            }
            openSMSConversation(sender)
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimOpenIncomingCall)) { _ in
            model.presentCurrentCallInApp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimOpenOtherAndroidCall)) { notification in
            let info = OtherAndroidCallPresentationRequest.consume() ?? notification.userInfo ?? [:]
            _ = model.openOtherDeviceCallNotification(info)
        }
        .alert(L10n.t("错误"), isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage?.isEmpty == false },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private func presentAppUpdateIfIdle() {
        guard scenePhase == .active, appUpdatePresentation == nil,
              appUpdateCallIdle, model.focusedOtherDeviceCall == nil,
              model.errorMessage == nil else { return }
        if appUpdates.needsNotes {
            appUpdatePresentation = .notes
        } else if firstConnectionComplete && selectedTabRawValue == PhoneTab.dial.rawValue,
                  let candidate = appUpdates.pendingUpdate {
            appUpdatePresentation = .result(.init(message: "发现应用新版本", candidate: candidate))
        }
    }

    private var appUpdateCallIdle: Bool {
        model.inAppPresentedCall == nil && model.activeCall == nil
            && model.remoteCall == nil && model.pendingOutgoingCall == nil
    }

    private func handleAppUpdateCallChange() {
        if !appUpdateCallIdle { appUpdatePresentation = nil }
        else { presentAppUpdateIfIdle() }
    }

    private var tabBinding: Binding<PhoneTab> {
        Binding(
            get: { PhoneTab(rawValue: selectedTabRawValue) ?? .home },
            set: { selectedTabRawValue = $0.rawValue }
        )
    }

    private var selectedTab: PhoneTab {
        get { PhoneTab(rawValue: selectedTabRawValue) ?? .home }
        nonmutating set { selectedTabRawValue = newValue.rawValue }
    }

    private func dial(_ number: String) {
        let agentID = AndroidAgentBindingPreference.selected() ?? model.currentAndroidAgent?.id
        if let agentID {
            let slots = model.simSlots(for: agentID)
            if slots.count > 1 {
                callbackSIMRequest = .init(agentID: agentID, number: number, slots: slots)
                return
            }
        }
        dialUsingCurrentSIM(number)
    }

    private func confirmCallbackSIM(_ request: CallbackSIMDialRequest, _ slot: AndroidSIMSlot) {
        let agentID = AndroidAgentBindingPreference.selected() ?? model.currentAndroidAgent?.id
        guard request.permits(agentID: agentID, liveSlots: agentID.map { model.simSlots(for: $0) } ?? [],
                              slotID: slot.id, callInProgress: model.callLifecycleSnapshot.state.representsCall || model.pendingOutgoingCall != nil) else {
            callbackSIMRequest = nil
            model.errorMessage = "设备或 SIM 卡已变化，请重新选择后拨号"
            return
        }
        model.selectSIMSlot(slot.id, for: request.agentID)
        callbackSIMRequest = nil
        dialUsingCurrentSIM(request.number)
    }

    private func dialUsingCurrentSIM(_ number: String) {
        showingConversation = false
        model.numberInput = number
        selectedTab = .dial
        Task { await model.dial() }
    }

    private func composeMessage(_ number: String) {
        showingConversation = false
        pendingSMSRecipient = number
        selectedTab = .messages
    }

    private func openSMSConversation(_ sender: String) {
        model.reloadMessagesFromLocalStore()
        showSMSConversation(sender)
    }

    private func showSMSConversation(_ sender: String) {
        selectedTab = .messages
        conversationSender = sender
        showingConversation = true
    }

    private func handleSystemCommunicationURL(_ url: URL) {
        if let target = AirSIMWidgetDestination.parse(url) {
            // Widget links only navigate. Never treat a widget tap as a dial or
            // SMS-send command, and never retarget an established call.
            if let id = target.agentID,
               !model.callLifecycleSnapshot.state.representsCall,
               !IPhoneCloudCallSession.shared.hasActiveCall,
               model.pairedAndroidAgents.contains(where: { $0.id == id }) {
                model.bindAndroidAgent(id)
            }
            switch target.destination {
            case .status: selectedTab = .settings
            case .dial: selectedTab = .dial
            case .messages: selectedTab = .messages
            case .contacts: selectedTab = .contacts
            case .recents: selectedTab = .recents
            }
            return
        }
        switch SystemCommunicationURL.destination(for: url) {
        case let .call(number):
            dial(number)
        case let .message(recipient):
            composeMessage(recipient)
        case let .liveActivity(action, callID):
            // Legacy links still open the app; use the same unified path as intents
            // so a stale island is dismissed instead of showing a Bluetooth-call error.
            Task { _ = await model.performLiveActivityAction(action, callID: callID) }
        case nil:
            break
        }
    }
}

/// Grouped backdrop (settings, home, 我的): system-style light gray / black.
struct PhoneBackdrop: View {
    var body: some View { Color(uiColor: WarmPalette.background).ignoresSafeArea() }
}

/// Design tokens (revision 2026-11-25): neutral system grays, the theme (暖橙 / 墨绿 / 天蓝) only picks
/// the accent, which marks selection and links — not every icon. No cream paper, no tinted surfaces.
enum WarmPalette {
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
    private static func dynamic(_ light: UIColor, _ dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
    static let background = dynamic(rgb(0xF2F2F7), rgb(0x000000)) // grouped pages and settings
    static let plain = dynamic(.white, rgb(0x000000))              // list pages, SMS timeline, tab bar
    static let card = dynamic(.white, rgb(0x1C1C1E))               // grouped cells, sheets
    static let raised = dynamic(.white, rgb(0x3A3A3C))             // selected segment
    static let cardBorder = dynamic(rgb(0xE0E0E5), rgb(0x38383A))  // separator
    static let soft = dynamic(rgb(0xEEEEF0), rgb(0x232325))        // search, segment track, incoming bubble
    static var accentSoft: UIColor { AppTheme.current.uiAccentSoft }
    static var onAccent: UIColor { AppTheme.current.uiOnAccent }
    static let textPrimary = dynamic(rgb(0x1C1C1E), rgb(0xF5F5F7))
    static let textSecondary = dynamic(rgb(0x6C6C70), rgb(0x98989F))
    static let textDisabled = dynamic(rgb(0xAEAEB2), rgb(0x636366))
    static let controlBorder = dynamic(rgb(0xC7C7CC), rgb(0x545458))
    static let positive = dynamic(rgb(0x248A3D), rgb(0x30D158))
    static let danger = dynamic(rgb(0xD70015), rgb(0xFF453A))
    static let call = dynamic(rgb(0x34C759), rgb(0x30D158))       // dial button only
    static let avatar = dynamic(rgb(0xB4B5BD), rgb(0x56565C))     // initials / unknown-number avatar
    static let warningText = dynamic(rgb(0x8A5300), rgb(0xFFCC66))
    static let warningSurface = dynamic(rgb(0xFFF4DE), rgb(0x2E2614))
    static let disabledFill = dynamic(rgb(0xE5E5EA), rgb(0x2C2C2E))
}

/// Grouped cell block: white / #1C1C1E on the grouped backdrop. No border, no shadow.
struct WarmCardSurface: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content.background(Color(uiColor: WarmPalette.card),
                           in: RoundedRectangle(cornerRadius: min(cornerRadius, 12), style: .continuous))
    }
}

struct PhoneGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass = interactive
                ? Glass.regular.tint(tint).interactive()
                : Glass.regular.tint(tint)
            content.glassEffect(
                glass,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08))
                }
        }
    }
}

extension View {
    /// Grouped settings forms sit on the paper backdrop instead of the system gray.
    func phoneListBackground() -> some View { scrollContentBackground(.hidden).background(PhoneBackdrop()) }

    func phoneGlassSurface(
        cornerRadius: CGFloat = 18,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(PhoneGlassSurface(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }
}

/// UI-only callback intent. The existing model/router remains the dial owner.
struct CallbackSIMDialRequest: Identifiable {
    let id = UUID()
    let agentID: String
    let number: String
    let slots: [AndroidSIMSlot]
    func permits(agentID current: String?, liveSlots: [AndroidSIMSlot], slotID: String, callInProgress: Bool) -> Bool {
        !callInProgress && current == agentID && slots.contains { $0.id == slotID }
            && liveSlots.contains { $0.id == slotID }
    }
}

private struct CallbackSIMDialChoice: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Binding var request: CallbackSIMDialRequest?
    let choose: (CallbackSIMDialRequest, AndroidSIMSlot) -> Void
    func body(content: Content) -> some View {
        content.overlay {
            Color.clear.frame(width: 1, height: 1)
                .popover(item: $request) { captured in
                    CompactSIMSelectionPanel(slots: captured.slots,
                        selectedID: model.selectedSIMSlotID(for: captured.agentID), title: "拨号用卡") { slot in
                        choose(captured, slot)
                    }.compactSIMPopoverPresentation()
                }
        }
    }
}
