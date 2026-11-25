import SwiftUI
import AVFoundation
import UIKit
import LinkPresentation
import PhotosUI
import UniformTypeIdentifiers
import ContactsUI

enum DialPadPasteSanitizer {
    static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "+*#0123456789")
        var filtered = String(value.unicodeScalars.filter { allowed.contains($0) })
        if filtered.dropFirst().contains("+") {
            filtered = String(filtered.enumerated().compactMap { index, character in
                character == "+" && index != 0 ? nil : character
            })
        }
        return String(filtered.prefix(64))
    }
}

enum SMSVerificationCodeClipboard {
    static let enabledKey = "airsim.auto-copy-sms-code"

    @MainActor
    static func handle(_ messages: [SMSMessage]) {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        guard enabled else { return }
        let recent = messages
            .filter { !$0.isOutgoing && $0.timestamp > Date().addingTimeInterval(-300) }
            .sorted { $0.timestamp < $1.timestamp }
        guard let message = recent.last,
              let code = SMSVerificationCodeExtractor.extract(from: message.content) else { return }
        let delivery = message.deliveryID ?? message.id
        guard defaults.string(forKey: "airsim.last-auto-copied-sms-code") != delivery else { return }
        UIPasteboard.general.string = code
        defaults.set(delivery, forKey: "airsim.last-auto-copied-sms-code")
    }
}

enum SMSVerificationCodeExtractor {
    static func extract(from text: String) -> String? {
        let patterns = [
            "(?:验证码|校验码|动态码|确认码|verification code|security code|code|otp)[^0-9]{0,24}([0-9]{4,8})",
            "(?<![0-9])([0-9]{4,8})(?![0-9])",
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = expression.firstMatch(in: text, options: [], range: range),
               let codeRange = Range(match.range(at: 1), in: text) {
                return String(text[codeRange])
            }
        }
        return nil
    }
}

enum PhoneContentSearch {
    static func numberMatches(_ number: String?, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        guard let number else { return false }
        if number.localizedStandardContains(query) { return true }
        let allowed = CharacterSet(charactersIn: "+0123456789 -().")
        guard query.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        func digits(_ value: String) -> String {
            let compact = value.filter { $0.isASCII && $0.isNumber }
            if value.trimmingCharacters(in: .whitespaces).hasPrefix("+86") { return String(compact.dropFirst(2)) }
            if value.trimmingCharacters(in: .whitespaces).hasPrefix("0086") { return String(compact.dropFirst(4)) }
            return compact
        }
        let token = digits(query)
        return !token.isEmpty && digits(number).contains(token)
    }
    static func smsMatches(sender: String, contactName: String?, messages: [SMSMessage], query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || numberMatches(sender, query: query)
            || contactName?.localizedStandardContains(query) == true
            || messages.contains { $0.content.localizedStandardContains(query) }
    }
}

enum RecentCallTimeFormatter {
    static func string(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let currentDay = calendar.dateComponents([.year, .month, .day], from: now)
        if day == currentDay {
            let time = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           day == calendar.dateComponents([.year, .month, .day], from: yesterday) {
            return "昨天"
        }
        if day.year == currentDay.year {
            return String(format: "%02d/%02d", day.month ?? 0, day.day ?? 0)
        }
        return String(format: "%04d/%02d/%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}

enum RecentCallDialPolicy {
    static func numberToDial(_ number: String?) -> String? {
        guard let number, !number.isEmpty else { return nil }
        return number
    }
}

enum DialPadDeletePolicy {
    static func removingLast(from number: String) -> String {
        String(number.dropLast())
    }
}

struct DialPadTransportPresentation: Equatable {
    let title: String
    let detail: String
    let systemImage: String
    let transport: CallTransport

    static func make(
        mode: AirSIMConnectionMode = .automatic,
        vowlanOnline: Bool,
        cloudOnline: Bool,
        bluetoothReady: Bool = false
    ) -> DialPadTransportPresentation? {
        let selected = DialRouteSelector.preferred(
            mode: mode,
            vowlanReady: vowlanOnline,
            bluetoothReady: bluetoothReady,
            cloudReady: cloudOnline
        )
        if selected == .vowlan {
            return DialPadTransportPresentation(
                title: "VoWLAN",
                detail: "拨号及通话音频将通过同一 Wi-Fi 或三星热点",
                systemImage: "wifi",
                transport: .vowlan
            )
        }
        if selected == .bluetooth {
            return DialPadTransportPresentation(
                title: "蓝牙",
                detail: "拨号及通话音频将通过 VoBLE，不使用 Relay",
                systemImage: "wave.3.right",
                transport: .bluetooth
            )
        }
        if selected == .cloud {
            return DialPadTransportPresentation(
                title: "云端",
                detail: "拨号及通话音频将通过云端 Relay",
                systemImage: "cloud.fill",
                transport: .cloud
            )
        }
        return nil
    }
}

/// Wide windows (iPad, landscape) put the call surface in two columns.
enum PhoneWindowLayout {
    static func usesTwoColumns(_ size: CGSize, accessibilitySize: Bool) -> Bool {
        !accessibilitySize && size.width >= 700 && size.height >= 280
    }
}

// MARK: - 按键音

enum DialToneTiming {
    static let minimumDuration: TimeInterval = 0.16
    static func releaseDelay(held: TimeInterval) -> TimeInterval { max(0, minimumDuration - max(0, held)) }
}

@MainActor final class LocalDialTone {
    static let shared = LocalDialTone()
    private var player: AVAudioPlayer?
    private var startedAt: TimeInterval = 0
    private var releaseTask: Task<Void, Never>?
    func start(_ digit: String) {
        stop()
        let rows = ["123", "456", "789", "*0#"]
        guard let row = rows.firstIndex(where: { $0.contains(digit) }),
              let column = rows[row].firstIndex(of: Character(digit)) else { return }
        let low = [697.0,770,852,941][row], high = [1209.0,1336,1477][rows[row].distance(from: rows[row].startIndex, to: column)]
        let rate = 44100, count = 8820
        var pcm = Data()
        for n in 0..<count {
            let t = Double(n) / Double(rate)
            let envelope = min(1, min(Double(n)/160, Double(count-1-n)/160))
            var sample = Int16((sin(2 * .pi * low * t) + sin(2 * .pi * high * t)) * 4500 * envelope).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func word<T: FixedWidthInteger>(_ number: T) { var value = number.littleEndian; withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) } }
        wav.append(Data("RIFF".utf8)); word(UInt32(36 + pcm.count)); wav.append(Data("WAVEfmt ".utf8))
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(rate)); word(UInt32(rate*2)); word(UInt16(2)); word(UInt16(16))
        wav.append(Data("data".utf8)); word(UInt32(pcm.count)); wav.append(pcm)
        // Never change AVAudioSession category/activation or PCM routing.
        startedAt = ProcessInfo.processInfo.systemUptime
        player = try? AVAudioPlayer(data: wav); player?.numberOfLoops = -1; player?.volume = 0.55; player?.play()
    }
    func stop(respectingMinimum: Bool = false) {
        releaseTask?.cancel(); releaseTask = nil
        let remaining = DialToneTiming.releaseDelay(held: ProcessInfo.processInfo.systemUptime - startedAt)
        if respectingMinimum, player != nil, remaining > 0 {
            releaseTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                self?.stop()
            }
            return
        }
        player?.stop(); player = nil
    }
}

// MARK: - 短信

private struct SMSAccountPicker: View {
    @EnvironmentObject private var model: AppModel
    let recipient: String
    /// The conversation's own line (what `sendReply` really uses); falls back to the bound device.
    var agentID: String? = nil
    var body: some View {
        if let agentID = agentID ?? model.currentAndroidAgent?.id ?? AndroidAgentBindingPreference.selected() {
            let slots = model.smsSIMSlots(for: agentID)
            if !slots.isEmpty {
                CompactSIMPicker(slots: slots,
                    selectedID: model.selectedSMSSlotID(for: agentID, recipient: recipient),
                    select: { slot in model.selectSMSSlot(slot.id, for: agentID, recipient: recipient) }) {
                    HStack(spacing: 4) {
                        Text(slots.first(where: { $0.id == model.selectedSMSSlotID(for: agentID, recipient: recipient) })?.label ?? "发送卡")
                            .lineLimit(1)
                        if slots.count > 1 { Image(systemName: "chevron.down").font(.caption2.weight(.semibold)) }
                    }
                    .font(.caption)
                }
                .disabled(slots.count < 2)
                .accessibilityLabel("发送线路，\(slots.first(where: { $0.id == model.selectedSMSSlotID(for: agentID, recipient: recipient) })?.label ?? "安卓默认短信卡")")
                .accessibilityIdentifier("sms.simSelector")
            } else {
                Label("安卓默认短信卡", systemImage: "simcard").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MessageThreadView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    let sender: String
    @State private var reply = ""
    @State private var pendingDeletion: Set<String> = []
    @State private var showingDeleteConfirmation = false
    @State private var selection = SMSMessageSelection()
    @FocusState private var composerFocused: Bool
    @State private var photoItem: PhotosPickerItem?
    @State private var pickedImage: Data?

    private var dateLocale: Locale {
        let language = settings.language == .system ? L10n.effectiveLanguage : settings.language
        var components = Locale.Components(locale: .autoupdatingCurrent)
        components.languageComponents.languageCode = language == .zh ? "zh" : "en"
        components.languageComponents.script = language == .zh ? "Hans" : nil
        return Locale(components: components)
    }

    private var messages: [SMSMessage] {
        model.messages
            .filter { SMSConversationKey.same($0.sender, sender) }
            .sorted { $0.timestamp < $1.timestamp }
    }


    private var trimmedReply: String {
        reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The line this conversation last used (e.g. a voip.ms number); replies go out on it.
    private var conversationLine: String? {
        messages.max { $0.timestamp < $1.timestamp }?.sourceAgentID
    }

    private var canSend: Bool { !trimmedReply.isEmpty || pickedImage != nil }

    private var replyBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pickedImage, let image = UIImage(data: pickedImage) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button {
                        self.pickedImage = nil
                        photoItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .accessibilityLabel(L10n.t("移除图片"))
                }
                .padding(.leading, 56)
            }
            HStack(alignment: .bottom, spacing: 6) {
                if model.agentSupportsMMS(conversationLine) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 20))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(L10n.t("添加图片"))
                    .accessibilityIdentifier("sms.photo")
                }
                messageField
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: SMSThemeColors.background))
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task { pickedImage = try? await item.loadTransferable(type: Data.self) }
        }
    }

    private var messageField: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(L10n.t("短信"), text: $reply, axis: .vertical)
                .accessibilityIdentifier("sms.reply")
                .focused($composerFocused)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.leading, 14)
                .padding(.trailing, canSend ? 2 : 14)
                .padding(.vertical, 8)
            if canSend {
                Button(action: sendReply) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.tint))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 5)
                .padding(.bottom, 3)
                .accessibilityLabel(L10n.t("发送"))
            }
        }
        .smsComposerGlass()
    }

    private func sendReply() {
        let body = trimmedReply
        // The bubble appears at once as "发送中…" and settles in the background.
        // Reply from the line this conversation last used (e.g. a voip.ms number), not
        // whichever device happens to be bound.
        let line = conversationLine
        if let image = pickedImage {
            if model.enqueueMMS(to: sender, content: body, imageData: image, agentID: line) {
                reply = ""
                pickedImage = nil
                photoItem = nil
            }
            return
        }
        guard !body.isEmpty else { return }
        if model.enqueueSMS(to: sender, content: body, agentID: line) { reply = "" }
    }

    var body: some View {
        VStack(spacing: 0) {
            SMSConversationTimelineView(
                messages: messages,
                selection: selection,
                locale: dateLocale,
                onBeginSelection: { id in
                    composerFocused = false
                    selection.begin(with: id)
                },
                onToggleSelection: { selection.toggle($0) },
                onBeginTextSelection: { composerFocused = false },
                onResend: { model.resendSMS($0) }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One plain page under the navigation bar, timeline and reply bar (no gray band at the top).
        .background(Color(uiColor: SMSThemeColors.background).ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection.isSelecting { selectionBar } else { replyBar }
        }
        .onChange(of: messages) { selection.reconcile(with: $0); acknowledgeVisibleMessages() }
        .onAppear { isVisible = true; acknowledgeVisibleMessages() }
        .onDisappear { isVisible = false }
        .onChange(of: scenePhase) { _ in acknowledgeVisibleMessages() }
        .onChange(of: model.inAppPresentedCall?.id) { _ in acknowledgeVisibleMessages() }
        .navigationTitle(model.contacts.displayName(for: sender))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        if model.contacts.contact(for: sender) == nil, let brand = SMSCarrierBrand.match(sender) {
                            SMSServiceArtwork(brand: brand, size: 22)
                        }
                        Text(model.contacts.displayName(for: sender)).font(.headline).lineLimit(1)
                    }
                    SMSAccountPicker(recipient: sender, agentID: conversationLine)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if selection.isSelecting {
                    Button {
                        selection.cancel()
                        composerFocused = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.t("取消选择"))
                }
            }
        }
        .confirmationDialog(
            String(format: L10n.t("删除所选 %d 条短信？"), pendingDeletion.count),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.t("删除"), role: .destructive) {
                let ids = pendingDeletion
                model.deleteMessages(ids: ids)
                // Persistence failure leaves the records and selection intact.
                if !model.messages.contains(where: { ids.contains($0.id) }) {
                    selection.cancel()
                }
                pendingDeletion = []
            }
            Button(L10n.t("取消"), role: .cancel) { pendingDeletion = [] }
        } message: { Text(L10n.t("仅删除此 iPhone 上 AirSIM 内的记录，不删除安卓系统短信。")) }
    }

    private func acknowledgeVisibleMessages() {
        guard isVisible, scenePhase == .active, model.inAppPresentedCall == nil else { return }
        model.markMessagesRead(messages)
    }

    private var selectionBar: some View {
        HStack {
            Button(role: .destructive) {
                pendingDeletion = selection.selectedIDs
                showingDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(L10n.t("删除所选短信"))
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .phoneGlassSurface(cornerRadius: 22, interactive: true)
            .disabled(selection.selectedIDs.isEmpty)
            Spacer()
            Text(String(format: L10n.t("已选 %d 条"), selection.selectedIDs.count))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer()
            SMSMessageShareButton(texts: selection.selectedMessages(in: messages).map(\.content))
                .frame(width: 44, height: 44)
                .phoneGlassSurface(cornerRadius: 22, interactive: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Anchor iPad's native activity popover to the tapped sharing button.
private struct SMSMessageShareButton: UIViewRepresentable {
    let texts: [String]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 22), forImageIn: .normal
        )
        button.tintColor = .label
        button.addAction(UIAction { [weak button, weak coordinator = context.coordinator] _ in
            guard let button else { return }
            coordinator?.share(from: button)
        }, for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.texts = texts
        button.isEnabled = !texts.isEmpty
        button.accessibilityLabel = L10n.t("共享所选短信")
    }

    final class Coordinator {
        var texts: [String] = []

        func share(from button: UIButton) {
            guard !texts.isEmpty else { return }
            var responder: UIResponder? = button
            while let current = responder {
                if let presenter = current as? UIViewController {
                    guard presenter.presentedViewController == nil else { return }
                    let title = texts.count == 1 ? L10n.t("1 条短信")
                        : String(format: L10n.t("%d 条短信"), texts.count)
                    let activity = UIActivityViewController(
                        activityItems: texts.map { SMSMessageShareItem(text: $0, title: title) },
                        applicationActivities: nil
                    )
                    if let popover = activity.popoverPresentationController {
                        popover.sourceView = button
                        popover.sourceRect = button.bounds
                    }
                    presenter.present(activity, animated: true)
                    return
                }
                responder = current.next
            }
        }
    }
}

private final class SMSMessageShareItem: NSObject, UIActivityItemSource {
    private let text: String
    private let title: String

    init(text: String, title: String) {
        self.text = text
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { text }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { text }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        UTType.plainText.identifier
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        return metadata
    }
}

struct MessageComposer: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var recipient: String
    @State private var content = ""
    @State private var sending = false
    @State private var showingContacts = false

    init(initialRecipient: String) { _recipient = State(initialValue: initialRecipient) }

    private var matchedContact: ContactStore.Contact? {
        model.contacts.contact(for: recipient)
    }

    private var suggestions: [ContactStore.Contact] {
        let query = recipient.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, matchedContact == nil else { return [] }
        return Array(model.contacts.contacts.filter { contact in
            contact.name.localizedCaseInsensitiveContains(query)
                || contact.phones.contains {
                    $0.localizedCaseInsensitiveContains(query) || $0.hasSuffix(query)
                }
        }.prefix(5))
    }

    private var canSend: Bool {
        !recipient.trimmingCharacters(in: .whitespaces).isEmpty
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sending
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                recipientBar
                HStack(spacing: 8) {
                    Text("发件线路：").font(.subheadline).foregroundStyle(.secondary)
                    SMSAccountPicker(recipient: recipient).disabled(sending)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)

                if !suggestions.isEmpty {
                    Divider()
                    contactSuggestions
                }

                Divider()
                Spacer(minLength: 0)
                Divider()
                messageInputBar
            }
            .background(Color(uiColor: SMSThemeColors.background).ignoresSafeArea())
            .navigationTitle(L10n.t("新信息"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("发送"), action: sendNow)
                        .disabled(!canSend)
                }
            }
            .task { await model.contacts.loadIfAuthorized(force: true) }
            .sheet(isPresented: $showingContacts) {
                MessageContactPicker { phone in
                    recipient = phone
                    showingContacts = false
                }
                .environmentObject(model)
            }
        }
    }

    private var recipientBar: some View {
        HStack(spacing: 9) {
            Button {
                showingContacts = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("从通讯录选择"))

            Text(L10n.t("收件人："))
                .foregroundStyle(.secondary)

            TextField(L10n.t("输入号码或姓名"), text: $recipient)
                .textFieldStyle(.plain)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)

            if let contact = matchedContact {
                HStack(spacing: 6) {
                    InitialAvatar(name: contact.name, photoData: contact.photoData, size: 28)
                    Text(contact.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: 130, alignment: .trailing)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("已识别联系人：\(contact.name)")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var contactSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { contact in
                    Button {
                        recipient = contact.phones.first ?? recipient
                    } label: {
                        HStack(spacing: 7) {
                            InitialAvatar(name: contact.name, photoData: contact.photoData, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(contact.name)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(contact.phones.first ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var messageInputBar: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 9) {
                TextField(L10n.t("短信内容"), text: $content, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )

                Button(action: sendNow) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            canSend ? Color.blue : Color.secondary.opacity(0.4),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(L10n.t("发送"))
            }

            Text(L10n.t("短信将通过 4G 模块发送"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: SMSThemeColors.background))
    }

    private func sendNow() {
        guard canSend else { return }
        // Recorded immediately as "发送中…"; delivery continues after the sheet closes.
        if model.enqueueSMS(to: recipient, content: content) { dismiss() }
    }
}

private struct MessageContactPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    let onSelect: (String) -> Void

    private var filteredContacts: [ContactStore.Contact] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.contacts.contacts }
        return model.contacts.contacts.filter { contact in
            contact.name.localizedCaseInsensitiveContains(query)
                || contact.phones.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.contacts.isAuthorized {
                    EmptyStateView(
                        title: L10n.t("授权访问通讯录"),
                        systemImage: "person.crop.circle.badge.questionmark",
                        actionTitle: L10n.t("授权访问通讯录")
                    ) {
                        Task { await model.contacts.requestAccessAndLoad() }
                    }
                } else if filteredContacts.isEmpty {
                    EmptyStateView(title: L10n.t("通讯录为空"), systemImage: "person.2")
                } else {
                    List(filteredContacts) { contact in
                        ForEach(contact.phones, id: \.self) { phone in
                            Button {
                                onSelect(phone)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    InitialAvatar(name: contact.name, photoData: contact.photoData)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(contact.name)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(phone)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(L10n.t("选择联系人"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: L10n.t("搜索姓名或号码"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
            }
            .task { await model.contacts.loadIfAuthorized(force: true) }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.contacts.isLimitedAccess {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("通讯录为受限访问，只显示已授权联系人；点此选择更多联系人", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.thinMaterial)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - 通讯录

private extension View {
    /// Message input field: surface fill, 1pt control border, radius 10 (no glass, no capsule).
    func smsComposerGlass() -> some View {
        background(Color(uiColor: WarmPalette.card), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(uiColor: WarmPalette.controlBorder), lineWidth: 1))
    }
}

enum AvatarFallbackContent: Equatable {
    case person
    case initial(String)
}

enum RecentAvatarPolicy {
    static func content(contactName: String?) -> AvatarFallbackContent {
        let trimmed = contactName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let first = trimmed.first else { return .person }
        return .initial(String(first))
    }
}

struct InitialAvatar: View {
    let name: String
    var photoData: Data? = nil
    var fallbackContent: AvatarFallbackContent? = nil
    var size: CGFloat = 44
    var serviceNumber: String? = nil
    var neutralFallback = false

    private var resolvedFallback: AvatarFallbackContent {
        fallbackContent
            ?? .initial(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)))
    }

    var body: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let serviceNumber, let brand = SMSCarrierBrand.match(serviceNumber) {
                SMSServiceArtwork(brand: brand, size: size)
            } else {
                warmFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var warmFallback: some View {
        Circle()
            .fill(Color(uiColor: WarmPalette.soft))
            .overlay {
                switch resolvedFallback {
                case .person:
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(.tint)
                case let .initial(initial):
                    Text(initial)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
    }

}

/// 新系统使用原生 ContentUnavailableView，iOS 16 保留等价回退。
private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(emptyStateDescription)
            } actions: {
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private var emptyStateDescription: String {
        switch systemImage {
        case "message": return "收到的短信会显示在这里。"
        case "phone.arrow.up.right": return "完成通话后，记录会显示在这里。"
        case "person.2": return "联系人会从系统通讯录同步。"
        default: return "完成连接或授权后即可使用。"
        }
    }
}

// MARK: - 通话覆盖层

enum CallSurfacePhase: Equatable {
    case incoming
    case outgoing
    case connected
}

enum CallSurfaceAction: Equatable {
    case decline
    case answer
    case mute
    case end
    case keypad
    case speaker
}

struct CallSurfaceContent: Equatable {
    let phase: CallSurfacePhase
    let primaryActions: [CallSurfaceAction]
    let secondaryActions: [CallSurfaceAction]
    let showsDuration: Bool

    init(state: String) {
        if ["incoming", "waiting"].contains(state) {
            phase = .incoming
            primaryActions = [.decline, .answer]
            secondaryActions = []
            showsDuration = false
        } else if ["active", "held"].contains(state) {
            phase = .connected
            primaryActions = [.end]
            secondaryActions = [.mute, .keypad, .speaker]
            showsDuration = true
        } else {
            phase = .outgoing
            primaryActions = [.end]
            secondaryActions = [.speaker]
            showsDuration = false
        }
    }
}

enum CallProximityPolicy {
    static func shouldMonitor(state: String, speakerEnabled: Bool) -> Bool {
        guard !speakerEnabled else { return false }
        return ["dialing", "alerting", "connecting", "active", "held", "ending"].contains(state)
    }
}

struct ActiveCallView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let call: CallRecord
    var isPresented = true
    var onMinimize: (() -> Void)? = nil
    @State private var showingKeypad = false

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var content: CallSurfaceContent { CallSurfaceContent(state: call.state) }
    private var controlSize: CGFloat { isCompact ? 80 : 84 }
    private var displayName: String { model.contacts.displayName(for: call.number) }
    private var callSIMLabel: String? {
        guard let slot = call.slotIndex, slot >= 0 else { return nil }
        let agentID = call.sourceAgentID ?? model.currentAndroidAgent?.id
        if let agentID,
           let info = model.simSlots(for: agentID).first(where: { $0.slotIndex == slot }) {
            let carrier = info.carrierName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return carrier.isEmpty ? "SIM \(slot + 1)" : "SIM \(slot + 1) · \(carrier)"
        }
        return "SIM \(slot + 1)"
    }
    private var contactPhotoData: Data? {
        guard let number = call.number else { return nil }
        return model.contacts.contact(for: number)?.photoData
    }

    var body: some View {
        ZStack {
            CallBackdrop()
            GeometryReader { proxy in
                let twoColumns = PhoneWindowLayout.usesTwoColumns(proxy.size,
                    accessibilitySize: dynamicTypeSize.isAccessibilitySize)
                ScrollView {
                    if twoColumns {
                        HStack(spacing: 32) {
                            callIdentity.frame(maxWidth: .infinity)
                            callActions.frame(maxWidth: .infinity)
                        }
                        .padding(24)
                        .frame(maxWidth: 1000, minHeight: proxy.size.height)
                        .frame(maxWidth: .infinity)
                    } else {
                        VStack(spacing: 0) {
                            callIdentity.padding(.top, proxy.size.height < 600 ? 20 : 56)
                            Spacer(minLength: 32)
                            callActions.padding(.bottom, 32)
                        }
                        .padding(.horizontal, 22)
                        .frame(maxWidth: 520, minHeight: proxy.size.height)
                        .frame(maxWidth: .infinity)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .contentShape(Rectangle())
        .sheet(isPresented: $showingKeypad) { DTMFKeypadView() }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(isPresented ? .dark : nil)
        .onAppear { updateProximityMonitoring() }
        .onChange(of: call.state) { _ in updateProximityMonitoring() }
        .onChange(of: isPresented) { _ in updateProximityMonitoring() }
        .onChange(of: call.id) { _ in showingKeypad = false }
        .onChange(of: model.audio.speakerEnabled) { _ in updateProximityMonitoring() }
        .onDisappear { UIDevice.current.isProximityMonitoringEnabled = false }
    }

    private var callIdentity: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.blue)
                    .frame(width: 16, height: 16)
                    .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
                Text("AirSIM 音频 –")
                if content.showsDuration {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(durationText(at: context.date)).monospacedDigit()
                    }
                } else {
                    Text(content.phase == .incoming ? "等待接听" : "正在呼叫")
                }
            }
            .font(.title3.weight(.medium))
            .foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 12) {
                if contactPhotoData != nil {
                    InitialAvatar(name: displayName, photoData: contactPhotoData, size: 32)
                        .accessibilityHidden(true)
                }
                Text(displayName)
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let number = call.number, number != displayName {
                Text(number).font(.title3.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)
            }
            let simLabel = [callSIMLabel, PhoneRegionLookup.serviceDescription(for: call.number) ?? PhoneRegionLookup.region(for: call.number)].compactMap { $0 }.joined(separator: " · ")
            if !simLabel.isEmpty {
                Text(simLabel).font(.subheadline).foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if content.phase == .incoming {
                connectivityBadge
            } else if model.audio.receiveOnly || !model.callAudioIsActive {
                // Keep early-media/recovery evidence visible; never imply a connected call.
                audioStatusBadge
            }
            if let error = model.audio.errorMessage, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var callActions: some View {
        if content.phase == .incoming {
            HStack(spacing: 48) {
                CallDecisionButton(title: L10n.t("拒接"), icon: "phone.down.fill", color: .red) {
                    Task { await model.reject() }
                }
                CallDecisionButton(title: L10n.t(model.answeringCall ? "接听中…" : "接听"),
                                   icon: "phone.fill", color: .green) {
                    Task { await model.answer() }
                }
                .disabled(model.answeringCall)
                .opacity(model.answeringCall ? 0.6 : 1)
            }
        } else {
            VStack(spacing: 24) {
                HStack(alignment: .top, spacing: 0) {
                    SpeakerRouteButton(audio: model.audio, size: controlSize, action: model.toggleSpeaker)
                        .frame(maxWidth: .infinity)
                    if let onMinimize {
                        CallCircleButton(title: "收起", icon: "arrow.down.right.and.arrow.up.left",
                                         color: nil, size: controlSize, action: onMinimize)
                            .accessibilityIdentifier("call.minimize")
                            .frame(maxWidth: .infinity)
                    }
                    CallCircleButton(title: model.isMuted ? "取消静音" : "静音", icon: "mic.slash.fill",
                        color: model.isMuted ? .white : nil,
                        foregroundColor: model.isMuted ? .black : .white, size: controlSize) {
                        Task { await model.toggleMute() }
                    }
                    .disabled(content.phase != .connected)
                    .frame(maxWidth: .infinity)
                }
                HStack(alignment: .top, spacing: 0) {
                    Menu {
                        Button {
                            Task { await model.toggleRecording() }
                        } label: {
                            Label(model.isRecording ? "停止录音" : "录音",
                                  systemImage: model.isRecording ? "stop.circle" : "record.circle")
                        }
                        .disabled(content.phase != .connected)
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: model.isRecording ? "record.circle.fill" : "ellipsis").font(.title2.weight(.semibold))
                                .foregroundStyle(model.isRecording ? Color.red : Color.white)
                                .frame(width: controlSize, height: controlSize)
                                .callControlGlass(tint: nil, shape: .circle)
                            Text("更多").font(.subheadline)
                        }
                        .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    CallDecisionButton(title: "结束", icon: "phone.down.fill",
                                       color: Color(red: 0.78, green: 0.06, blue: 0.04), size: controlSize) {
                        Task { await model.hangup() }
                    }
                    .accessibilityLabel("挂断")
                    .frame(maxWidth: .infinity)
                    CallCircleButton(title: "拨号键盘", icon: "circle.grid.3x3.fill", color: nil,
                                     size: controlSize) { showingKeypad = true }
                        .disabled(content.phase != .connected)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var connectivityBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(moduleIsReachable ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(connectivityText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .background(Color.white.opacity(0.08), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var audioStatusBadge: some View {
        let statusColor = model.audio.receiveOnly ? Color.blue : (model.callAudioIsActive ? Color.green : audioStatusColor)
        return HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(model.callAudioStatusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
            if model.audio.active, !model.audio.routeDescription.isEmpty {
                Text("· \(model.audio.routeDescription)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 38)
        .background(Color.white.opacity(0.08), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var moduleIsReachable: Bool {
        model.callConnectionIsReady
    }

    private var connectivityText: String {
        if model.bluetoothIncomingRecoveryPending { return "正在恢复蓝牙连接，请稍候…" }
        if model.callUsesBluetooth { return moduleIsReachable ? "蓝牙已连接" : "蓝牙连接中" }
        let status = moduleIsReachable ? "模块在线" : "模块连接中"
        let signal = model.modemStatus?.signalDBM ?? model.cloudAgentStatus?.signalDBM
        guard let signal else { return status }
        return "\(status) · 信号 \(signal) dBm"
    }

    private var audioStatusColor: Color {
        switch model.cloudCallAudioState {
        case .failed: return .red
        case .connected: return .green
        case .connecting: return .orange
        case .idle: return model.audio.active ? .green : .orange
        }
    }

    private func durationText(at date: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(model.callConnectedAt ?? date)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func updateProximityMonitoring() {
        UIDevice.current.isProximityMonitoringEnabled = isPresented && CallProximityPolicy.shouldMonitor(
            state: call.state,
            speakerEnabled: model.audio.speakerEnabled
        )
    }
}

private struct SpeakerRouteButton: View {
    @ObservedObject var audio: AudioSessionController
    let size: CGFloat
    let action: () -> Void

    private var outputTitle: String {
        if audio.speakerEnabled { return "扬声器" }
        let output = AVAudioSession.sharedInstance().currentRoute.outputs.first
        if output == nil || output?.portType == .builtInReceiver { return "听筒" }
        return "音频"
    }

    var body: some View {
        CallCircleButton(
            title: outputTitle,
            icon: "speaker.wave.2.fill",
            color: audio.speakerEnabled ? .white : nil,
            foregroundColor: audio.speakerEnabled ? .black : .white,
            size: size,
            action: action
        )
        .accessibilityValue(audio.speakerEnabled ? "已开启" : "已关闭")
        .accessibilityHint(audio.routeDescription)
    }
}

private struct CallDecisionButton: View {
    let title: String
    let icon: String
    let color: Color
    var size: CGFloat = 76
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Circle()
                    .fill(color.gradient)
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .frame(width: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct CallCircleButton: View {
    let title: String
    let icon: String
    let color: Color?
    var foregroundColor: Color = .white
    var size: CGFloat = 68
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Circle().fill(.clear).frame(width: size, height: size).overlay {
                    Image(systemName: icon).font(.title2.weight(.semibold)).foregroundStyle(foregroundColor)
                }
                .callControlGlass(tint: color, shape: .circle)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.88))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: size, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CallBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: Color(red: 0.13, green: 0.25, blue: 0.40), location: 0),
                .init(color: Color(red: 0.18, green: 0.31, blue: 0.48), location: 0.28),
                .init(color: Color(red: 0.18, green: 0.24, blue: 0.34), location: 0.68),
                .init(color: Color(red: 0.18, green: 0.19, blue: 0.19), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.41, green: 0.28, blue: 0.35).opacity(0.38), .clear],
                center: UnitPoint(x: 0.9, y: 0.48), startRadius: 0, endRadius: 440)
        }
        .ignoresSafeArea()
    }
}

private enum CallControlShape { case capsule, circle }

private struct CallControlGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let tint: Color?
    let shape: CallControlShape

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            switch shape {
            case .capsule:
                content.background(tint ?? Color(white: 0.20), in: Capsule())
            case .circle:
                content.background(tint ?? Color(white: 0.20), in: Circle())
            }
        } else if #available(iOS 26.0, *) {
            switch shape {
            case .capsule:
                content.glassEffect(.regular.tint(tint).interactive(), in: Capsule())
            case .circle:
                content.glassEffect(.clear.tint(tint ?? .white.opacity(0.06)).interactive(), in: Circle())
            }
        } else {
            switch shape {
            case .capsule:
                content.background(.ultraThinMaterial, in: Capsule())
            case .circle:
                content.background(.ultraThinMaterial, in: Circle())
                    .background(tint ?? .clear, in: Circle())
            }
        }
    }
}

private extension View {
    func callControlGlass(
        tint: Color? = nil,
        shape: CallControlShape = .capsule
    ) -> some View {
        modifier(CallControlGlass(tint: tint, shape: shape))
    }
}

private struct DTMFKeypadView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var model: AppModel
    @State private var enteredDigits = ""
    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    private var keySize: CGFloat { horizontalSizeClass == .compact ? 62 : 70 }

    var body: some View {
        NavigationStack {
            ScrollView {
              VStack(spacing: 20) {
                Text(enteredDigits.isEmpty ? "按键发送双音多频" : enteredDigits)
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                    .foregroundStyle(enteredDigits.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .accessibilityLabel(enteredDigits.isEmpty ? "尚未输入按键" : enteredDigits)
                if #available(iOS 26.0, *) {
                    GlassEffectContainer(spacing: 16) { keypad }
                } else {
                    keypad
                }
              }
              .frame(maxWidth: .infinity)
              .padding(24)
            }
            .navigationTitle("通话键盘")
            .toolbar { Button(L10n.t("取消")) { dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var keypad: some View {
        VStack(spacing: 16) {
            ForEach(rows, id: \.description) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { digit in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            enteredDigits = String((enteredDigits + digit).suffix(18))
                            Task { await model.sendDTMF(digit) }
                        } label: {
                            VStack(spacing: 1) {
                                Text(digit).font(.system(size: 29, weight: .regular))
                                Text(["2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL",
                                      "6": "MNO", "7": "PQRS", "8": "TUV", "9": "WXYZ"][digit] ?? " ")
                                    .font(.caption2.weight(.semibold)).tracking(1.5)
                                    .accessibilityHidden(true)
                            }
                            .frame(width: keySize, height: keySize)
                            .contentShape(Circle())
                        }
                        .buttonStyle(DTMFGlassButtonStyle())
                        .accessibilityLabel("发送 DTMF \(digit)")
                    }
                }
            }
        }
    }
}

private struct DTMFGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                configuration.label
                    .glassEffect(.regular.tint(configuration.isPressed ? .cyan : .clear).interactive(), in: Circle())
            } else {
                configuration.label
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().fill(Color.cyan.opacity(configuration.isPressed ? 0.28 : 0)))
            }
        }
        .foregroundStyle(configuration.isPressed ? Color.cyan : Color.primary)
        .scaleEffect(configuration.isPressed ? 0.91 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}


/// Shared presentation only. Callers retain their existing SIM actions.
struct CompactSIMPicker<LabelContent: View>: View {
    let slots: [AndroidSIMSlot]
    let selectedID: String?
    let select: (AndroidSIMSlot) -> Void
    @ViewBuilder let label: () -> LabelContent
    @State private var isPresented = false
    var body: some View {
        Button { isPresented = true } label: { label() }
            .popover(isPresented: $isPresented) {
                CompactSIMSelectionPanel(slots: slots, selectedID: selectedID) { slot in
                    isPresented = false
                    select(slot)
                }.compactSIMPopoverPresentation()
            }
    }
}

struct CompactSIMSelectionPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let slots: [AndroidSIMSlot]
    let selectedID: String?
    var title: String? = nil
    let select: (AndroidSIMSlot) -> Void

    static func title(for slot: AndroidSIMSlot) -> String {
        let card = slot.slotIndex.map { "SIM \($0 + 1)" } ?? slot.label
        if let carrier = slot.carrierName?.trimmingCharacters(in: .whitespacesAndNewlines), !carrier.isEmpty {
            return "\(card) · \(carrier)"
        }
        // The legacy label may already contain its carrier. Never append the
        // full subscriber number or build a second oversized description row.
        return slot.label.isEmpty ? card : slot.label
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            }
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                Button {
                    select(slot)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "simcard").font(.system(size: 16)).foregroundStyle(.tint).frame(width: 20)
                        Text(Self.title(for: slot)).font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tint).opacity(selectedID == slot.id ? 1 : 0)
                    }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.title(for: slot))
                .accessibilityAddTraits(selectedID == slot.id ? .isSelected : [])
                if index < slots.count - 1 { Divider().padding(.leading, 42).padding(.trailing, 12) }
            }
        }.padding(.vertical, title == nil ? 4 : 0)
            .padding(.bottom, title == nil ? 0 : 4)
            .frame(width: dynamicTypeSize.isAccessibilitySize ? 300 : 232)
    }
    var body: some View {
        if #available(iOS 26.0, *) {
            rows.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        } else {
            rows.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

extension View {
    @ViewBuilder func compactSIMPopoverPresentation() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCompactAdaptation(.popover).presentationBackground(.clear)
        } else { self }
    }
}


/// Mainland-China number allocation labels, loaded locally. Never a live location.
enum PhoneRegionLookup {
    struct Table: Sendable {
        let data: Data
        let regions: [String]
        let count: Int
        let recordsOffset: Int
        init?(data: Data) {
            guard data.count >= 16, data.prefix(8) == Data("ASREG001".utf8) else { return nil }
            func u32(_ offset: Int) -> Int { data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) } }
            let count = u32(8), regionCount = u32(12)
            guard count > 0, count <= 800_000, regionCount > 0, regionCount < 10_000 else { return nil }
            var offset = 16
            var names: [String] = []
            for _ in 0..<regionCount {
                guard offset + 2 <= data.count else { return nil }
                let length = data.withUnsafeBytes { Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))) }
                offset += 2
                guard offset + length <= data.count,
                      let name = String(data: data.subdata(in: offset..<(offset + length)), encoding: .utf8) else { return nil }
                names.append(name); offset += length
            }
            guard offset + count * 10 == data.count else { return nil }
            self.data = data; self.regions = names; self.count = count; self.recordsOffset = offset
        }
        func region(for prefix: UInt64) -> String? {
            data.withUnsafeBytes { bytes in
                var low = 0, high = count
                while low < high {
                    let mid = (low + high) / 2, offset = recordsOffset + mid * 10
                    let value = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                    if value < prefix { low = mid + 1 } else { high = mid }
                }
                guard low < count else { return nil }
                let offset = recordsOffset + low * 10
                guard UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) == prefix else { return nil }
                let index = Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt16.self)))
                return regions.indices.contains(index) ? regions[index] : nil
            }
        }
    }
    static let table: Table? = {
        let url = Bundle.main.url(forResource: "PhoneRegionCN", withExtension: "dat")
            ?? Bundle.main.url(forResource: "PhoneRegionCN", withExtension: "dat", subdirectory: "PhoneRegionResources")
        guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return Table(data: data)
    }()
    static func normalizedCN(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "+0123456789 -().\u{00a0}")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !trimmed.dropFirst().contains("+") else { return nil }
        var digits = trimmed.filter { $0.isASCII && $0.isNumber }
        let international = trimmed.hasPrefix("+86") || trimmed.hasPrefix("0086")
        if trimmed.hasPrefix("+"), !trimmed.hasPrefix("+86") { return nil }
        if trimmed.hasPrefix("0086") { digits = String(digits.dropFirst(4)) }
        else if trimmed.hasPrefix("+86") { digits = String(digits.dropFirst(2)) }
        else if digits.count == 13 && digits.hasPrefix("86") { digits = String(digits.dropFirst(2)) }
        if digits.hasPrefix("400") || digits.hasPrefix("800") { return nil }
        if digits.count == 11, digits.first == "1", let second = digits.dropFirst().first, "3456789".contains(second) { return "86" + digits }
        if digits.hasPrefix("0") { digits.removeFirst() }
        else if !international { return nil }
        guard (9...11).contains(digits.count), digits.hasPrefix("10") || digits.first.map({ "23456789".contains($0) }) == true else { return nil }
        return "86" + digits
    }
    static func region(for raw: String?) -> String? {
        guard let number = normalizedCN(raw), let table else { return nil }
        for length in (4...min(15, number.count)).reversed() {
            if let prefix = UInt64(number.prefix(length)), let region = table.region(for: prefix), region != "中国" { return region }
        }
        return nil
    }
    // Service prefixes identify a number category, never a verified caller/company.
    static func serviceDescription(for raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "+0123456789 -().").contains($0) }),
              !value.dropFirst().contains("+") else { return nil }
        var digits = value.filter { $0.isASCII && $0.isNumber }
        if value.hasPrefix("+") {
            guard value.hasPrefix("+86") else { return nil }
            digits = String(digits.dropFirst(2))
        } else if value.hasPrefix("00") {
            guard value.hasPrefix("0086") else { return nil }
            digits = String(digits.dropFirst(4))
        }
        guard (5...8).contains(digits.count) else { return nil }
        if digits.hasPrefix("95") { return "国内 95 服务号码" }
        if digits.hasPrefix("96") { return "国内 96 服务号码" }
        return nil
    }
    static func infoLine(number: String?, slotIndex: Int?, fallbackSIM: String? = nil) -> String? {
        let region = serviceDescription(for: number) ?? region(for: number)
        let slot = slotIndex.flatMap { $0 >= 0 ? "SIM \($0 + 1)" : nil }
        if let region { return [slot, region].compactMap { $0 }.joined(separator: " · ") }
        return fallbackSIM ?? slot
    }
}
