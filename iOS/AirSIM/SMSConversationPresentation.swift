import AVFoundation
import CallKit
import CryptoKit
import Foundation
import UIKit

struct SMSMessageSelection: Equatable {
    private(set) var isSelecting = false
    private(set) var selectedIDs: Set<String> = []

    init() {}

    mutating func begin(with id: String) {
        isSelecting = true
        selectedIDs = [id]
    }

    mutating func toggle(_ id: String) {
        guard isSelecting else { return }
        if !selectedIDs.insert(id).inserted {
            selectedIDs.remove(id)
        }
    }

    mutating func cancel() {
        isSelecting = false
        selectedIDs.removeAll()
    }

    mutating func reconcile(with messages: [SMSMessage]) {
        selectedIDs.formIntersection(messages.map(\.id))
    }

    func selectedMessages(in messages: [SMSMessage]) -> [SMSMessage] {
        SMSConversationPresentation.chronological(messages.filter { selectedIDs.contains($0.id) })
    }
}

struct SMSTimelineItem: Equatable, Identifiable {
    let message: SMSMessage
    let showsTimestamp: Bool
    let showsTail: Bool

    var id: String { message.id }
}

enum SMSConversationPresentation {
    private static let formatters = SMSConversationTimestampFormatters()

    static func timeline(
        _ messages: [SMSMessage],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [SMSTimelineItem] {
        let ordered = chronological(messages)
        return ordered.indices.map { index in
            let message = ordered[index]
            let showsTimestamp = index == ordered.startIndex
                || startsTimestampGroup(message, after: ordered[index - 1], calendar: calendar)
            let nextIndex = index + 1
            let showsTail = nextIndex == ordered.endIndex
                || ordered[nextIndex].isOutgoing != message.isOutgoing
                || startsTimestampGroup(ordered[nextIndex], after: message, calendar: calendar)
            return SMSTimelineItem(message: message, showsTimestamp: showsTimestamp, showsTail: showsTail)
        }
    }

    static func timestamp(
        _ date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        formatters.string(from: date, relativeTo: now, calendar: calendar, locale: locale)
    }

    fileprivate static func chronological(_ messages: [SMSMessage]) -> [SMSMessage] {
        messages.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
    }

    private static func startsTimestampGroup(
        _ message: SMSMessage,
        after previous: SMSMessage,
        calendar: Calendar
    ) -> Bool {
        !calendar.isDate(message.timestamp, inSameDayAs: previous.timestamp)
            || message.timestamp.timeIntervalSince(previous.timestamp) >= 300
    }
}

/// A single bounded cache keeps formatter allocation out of row rendering. The lock protects
/// both configuration changes and formatting when callers use different calendars or locales.
private final class SMSConversationTimestampFormatters: @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: Configuration?
    private let time = DateFormatter()
    private let weekday = DateFormatter()
    private let monthDay = DateFormatter()
    private let fullDate = DateFormatter()
    private let relativeDay = RelativeDateTimeFormatter()

    private struct Configuration: Equatable {
        let calendar: Calendar
        let locale: Locale
    }

    func string(from date: Date, relativeTo now: Date, calendar: Calendar, locale: Locale) -> String {
        lock.lock()
        defer { lock.unlock() }
        let requested = Configuration(calendar: calendar, locale: locale)
        if configuration != requested {
            for formatter in [time, weekday, monthDay, fullDate] {
                formatter.locale = locale
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
            }
            time.dateStyle = .none
            time.timeStyle = .short
            weekday.setLocalizedDateFormatFromTemplate("EEEE")
            monthDay.setLocalizedDateFormatFromTemplate("MMMd")
            fullDate.setLocalizedDateFormatFromTemplate("yMMMd")
            relativeDay.locale = locale
            relativeDay.calendar = calendar
            relativeDay.dateTimeStyle = .named
            relativeDay.unitsStyle = .full
            relativeDay.formattingContext = .beginningOfSentence
            configuration = requested
        }

        let dayDistance = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day
        let dayLabel: String
        switch dayDistance ?? Int.max {
        case 0:
            dayLabel = relativeDay.localizedString(from: DateComponents(day: 0))
        case 1:
            dayLabel = relativeDay.localizedString(from: DateComponents(day: -1))
        case 2...6:
            dayLabel = weekday.string(from: date)
        default:
            let dateYear = calendar.dateComponents([.era, .year], from: date)
            let currentYear = calendar.dateComponents([.era, .year], from: now)
            dayLabel = dateYear == currentYear ? monthDay.string(from: date) : fullDate.string(from: date)
        }
        return "\(dayLabel) \(time.string(from: date))"
    }
}

// MARK: - MMS / voicemail media

/// Local copies of SMS attachments: outgoing MMS images and downloaded MMS media / voicemail audio.
actor SMSMediaStore {
    static let shared = SMSMediaStore()
    private var downloads: [String: Task<URL, Error>] = [:]

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("AirSIM-SMS-Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    nonisolated static func localURL(_ name: String) -> URL {
        directory.appendingPathComponent((name as NSString).lastPathComponent)
    }

    /// Stores picked image bytes; returns the file name kept in `SMSAttachment.localFile`.
    nonisolated static func saveOutgoing(_ data: Data, fileExtension: String = "jpg") throws -> String {
        let name = "out-\(UUID().uuidString.lowercased()).\(fileExtension)"
        try data.write(to: localURL(name), options: .atomic)
        return name
    }

    nonisolated static func cachedFile(for attachment: SMSAttachment) -> URL? {
        if let name = attachment.localFile {
            let url = localURL(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        guard let remote = attachment.url else { return nil }
        let url = localURL(cacheName(remote))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private nonisolated static func cacheName(_ remote: String) -> String {
        let digest = SHA256.hash(data: Data(remote.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        let ext = URL(string: remote).map { $0.pathExtension }.flatMap { $0.isEmpty ? nil : $0 } ?? "bin"
        return "in-\(digest).\(ext)"
    }

    /// A local file for the attachment, downloading it once (concurrent callers share the request).
    func file(for attachment: SMSAttachment) async throws -> URL {
        if let cached = Self.cachedFile(for: attachment) { return cached }
        guard let remote = attachment.url, let source = URL(string: remote), source.scheme == "https" else {
            throw URLError(.badURL)
        }
        if let running = downloads[remote] { return try await running.value }
        let task = Task<URL, Error> {
            var request = URLRequest(url: source)
            request.timeoutInterval = 60
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw URLError(.badServerResponse) }
            let target = Self.localURL(Self.cacheName(remote))
            try data.write(to: target, options: .atomic)
            return target
        }
        downloads[remote] = task
        defer { downloads[remote] = nil }
        return try await task.value
    }
}

enum MMSImageEncoder {
    /// voip.ms accepts MMS media up to ~1.2 MB: scale to ≤1600 px and lower JPEG quality until it fits.
    static func jpeg(from data: Data, maxBytes: Int = 1_000_000) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1600 / max(longest, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        var quality: CGFloat = 0.8
        while quality > 0.2 {
            if let encoded = rendered.jpegData(compressionQuality: quality), encoded.count <= maxBytes { return encoded }
            quality -= 0.15
        }
        return rendered.jpegData(compressionQuality: 0.2)
    }
}

/// Inline voicemail / audio playback for SMS bubbles (one clip at a time).
@MainActor
final class SMSAudioPlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = SMSAudioPlayback()
    static let didChange = Notification.Name("airsim.sms-audio-playback.changed")
    private var player: AVAudioPlayer?
    private(set) var playingKey: String?
    private var timer: Timer?

    var progress: Double {
        guard let player, player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }
    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval { player?.duration ?? 0 }

    func isPlaying(_ key: String) -> Bool { playingKey == key && player?.isPlaying == true }

    func toggle(key: String, file: URL) {
        if isPlaying(key) { stop(); return }
        stop()
        do {
            // Never take over the audio route of a call in progress.
            guard CXCallObserver().calls.allSatisfy(\.hasEnded) else { return }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: file)
            player.delegate = self
            player.play()
            self.player = player
            playingKey = key
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                Task { @MainActor in NotificationCenter.default.post(name: Self.didChange, object: nil) }
            }
        } catch {
            stop()
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingKey = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
