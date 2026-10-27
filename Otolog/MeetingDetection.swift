import Foundation
import AppKit
import CoreAudio
import ApplicationServices

struct MeetingCandidate: Equatable, Identifiable {
    let bundleID: String
    let appName: String
    let serviceName: String?
    var meetingName: String? = nil
    var id: String { bundleID }
    var title: String { meetingName ?? serviceName ?? appName }
    var explanation: String {
        serviceName == nil ? "\(appName)のマイク利用を検知しました．会議以外の場合もあります．" : "\(serviceName ?? appName)の会議候補を検知しました．"
    }
}
enum MeetingDetectionRules {
    static let browsers: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.apple.Safari", "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser", "company.thebrowser.Browser"]
    static let nativeApps: [String: String] = ["us.zoom.xos": "Zoom", "com.microsoft.teams": "Microsoft Teams", "com.microsoft.teams2": "Microsoft Teams"]
    static func candidate(bundle: String, appName: String, inputActive: Bool, windowTitles: [String]) -> MeetingCandidate? {
        guard inputActive else { return nil }
        if let service = nativeApps[bundle] { return MeetingCandidate(bundleID: bundle, appName: appName, serviceName: service, meetingName: MeetingTitles.name(in: windowTitles, service: service, native: true)) }
        guard browsers.contains(bundle) else { return nil }
        let titles = windowTitles.map { $0.lowercased() }
        let service: String?
        if titles.contains(where: { $0.contains("google meet") || $0.hasPrefix("meet - ") || $0.hasPrefix("meet – ") }) { service = "Google Meet" }
        else if titles.contains(where: { $0.contains("microsoft teams") }) { service = "Microsoft Teams（ブラウザー）" }
        else if titles.contains(where: { $0.contains("zoom meeting") || $0.contains("zoom web app") }) { service = "Zoom（ブラウザー）" }
        else { service = nil }
        return MeetingCandidate(bundleID: bundle, appName: appName, serviceName: service, meetingName: service.flatMap { MeetingTitles.name(in: windowTitles, service: $0, native: false) })
    }
}
enum MeetingTitles {
    private static let generic: Set<String> = ["zoom", "zoom meeting", "zoom meetings", "zoom workplace", "zoomミーティング", "zoom ミーティング", "ミーティング", "microsoft teams", "teams", "google meet", "meet", "home", "ホーム", "chat", "チャット", "calendar", "カレンダー", "settings", "設定", "google chrome", "microsoft edge", "mozilla firefox", "firefox", "safari", "brave", "arc"]
    static func name(in titles: [String], service: String, native: Bool) -> String? {
        let serviceKey = service.lowercased()
        let matching = titles.filter { title in
            let value = title.lowercased()
            if serviceKey.contains("meet") && !serviceKey.contains("teams") { return value.contains("google meet") || value.hasPrefix("meet - ") || value.hasPrefix("meet – ") }
            if serviceKey.contains("teams") { return value.contains("teams") }
            return value.contains("zoom")
        }
        // Native applications sometimes expose only the meeting's subject, without a service suffix.
        for title in matching + (native ? titles.filter { !matching.contains($0) } : []) {
            let parts = title.components(separatedBy: CharacterSet(charactersIn: "|"))
                .flatMap { $0.components(separatedBy: " - ") }
                .flatMap { $0.components(separatedBy: " — ") }
                .flatMap { $0.components(separatedBy: " – ") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !generic.contains($0.lowercased()) }
            let value = parts.joined(separator: " - ")
            if !value.isEmpty { return String(value.prefix(160)) }
        }
        return nil
    }
}
/// Two observations debounce transient input. A 30-second inactive period starts a new episode.
struct MeetingNotificationGate {
    private struct Episode { var count: Int; var lastSeen: Double; var notified: Bool }
    private var episodes: [String: Episode] = [:]
    mutating func update(_ candidates: [MeetingCandidate], now: Double, blocked: Bool) -> MeetingCandidate? {
        let active = Set(candidates.map(\.id))
        episodes = episodes.filter { active.contains($0.key) || now - $0.value.lastSeen < 30 }
        for key in Array(episodes.keys) where !active.contains(key) { episodes[key]?.count = 0 }
        for candidate in candidates {
            var episode = episodes[candidate.id] ?? Episode(count: 0, lastSeen: now, notified: false)
            if now - episode.lastSeen >= 30 { episode = Episode(count: 0, lastSeen: now, notified: false) }
            else if now - episode.lastSeen > 6 { episode.count = 0 }
            episode.count += 1; episode.lastSeen = now
            if blocked { episode.notified = true }
            episodes[candidate.id] = episode
        }
        guard !blocked else { return nil }
        for candidate in candidates {
            guard var episode = episodes[candidate.id], episode.count >= 2, !episode.notified else { continue }
            episode.notified = true; episodes[candidate.id] = episode
            return candidate
        }
        return nil
    }
}

@MainActor final class MeetingDetector {
    private let worker = DispatchQueue(label: "Otolog.meeting-detection", qos: .utility)
    private var timer: Timer?
    private var inFlight = false
    private var generation = 0
    private var gate = MeetingNotificationGate()
    var blocked: (() -> Bool)?
    var detected: ((MeetingCandidate) -> Void)?
    var inspectWindowTitles = false
    func start() {
        guard timer == nil else { return }
        generation += 1
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        scan()
    }
    func stop() { timer?.invalidate(); timer = nil; generation += 1; gate = MeetingNotificationGate() }
    private func scan() {
        guard !inFlight, timer != nil else { return }
        inFlight = true
        let token = generation, titlesEnabled = inspectWindowTitles
        let apps = NSWorkspace.shared.runningApplications.filter {
            guard let bundle = $0.bundleIdentifier else { return false }
            return MeetingDetectionRules.nativeApps[bundle] != nil || MeetingDetectionRules.browsers.contains(bundle)
        }.compactMap { app -> (String, String, pid_t)? in
            guard let bundle = app.bundleIdentifier else { return nil }
            return (bundle, app.localizedName ?? bundle, app.processIdentifier)
        }.sorted { $0.0 < $1.0 }
        worker.async { [weak self] in
            let candidates = apps.compactMap { bundle, name, pid -> MeetingCandidate? in
                let inputActive = Devices.processes(for: bundle).contains { id in
                    (try? property(id, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) == 1
                }
                let titles = inputActive && titlesEnabled ? Self.windowTitles(pid: pid) : []
                return MeetingDetectionRules.candidate(bundle: bundle, appName: name, inputActive: inputActive, windowTitles: titles)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard self.generation == token, self.timer != nil else { return }
                if let result = self.gate.update(candidates, now: hostSeconds(), blocked: self.blocked?() ?? false) {
                    self.detected?(result)
                }
            }
        }
    }
    nonisolated private static func windowTitles(pid: pid_t) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let elements = windows as? [AXUIElement] else { return [] }
        return elements.prefix(5).compactMap { window in
            AXUIElementSetMessagingTimeout(window, 0.2)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return nil }
            return (value as? String).map { String($0.prefix(512)) }
        }
    }
    static func requestTitleAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
