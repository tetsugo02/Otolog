import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ApplicationServices

@MainActor final class AppModel: ObservableObject {
    enum State: String { case idle = "待機中", starting = "録音準備中", recording = "録音中", saving = "保存処理中" }
    @Published var state: State = .idle
    @Published var mode: RecordingMode = .meeting
    @Published var target = "all"
    @Published var recordingName = ""
    @Published var microphoneID = ""
    @Published var micEnabled = true
    @Published var targets: [AudioTarget] = []
    @Published var microphones: [AVCaptureDevice] = []
    @Published var elapsed = 0.0
    @Published var peaks: [Float] = [0, 0]
    @Published var formats = ["入力待ち", "入力待ち"]
    @Published var playback: PlaybackReception = .waiting
    @Published var message: String?
    @Published var lastFile: URL?
    @Published var destination: URL
    @Published var recoveries: [URL] = []
    @Published var detectionEnabled = UserDefaults.standard.object(forKey: "meetingDetectionEnabled") as? Bool ?? true
    @Published var meetingTitlesEnabled = UserDefaults.standard.bool(forKey: "browserTitlesEnabled")
    @Published var askNameOnStop = UserDefaults.standard.bool(forKey: "askNameOnStop")
    private let detector = MeetingDetector()
    private let prompt = MeetingPromptController()
    private var recorder: Recorder?
    private var connectionObservers: [NSObjectProtocol] = []
    var busy: Bool { state != .idle }
    var recordsMicrophone: Bool { mode == .microphone || micEnabled }
    var microphoneName: String { microphones.first { $0.uniqueID == microphoneID }?.localizedName ?? "マイク未選択" }
    var statusLabel: String {
        state == .recording && mode == .meeting && playback != .receiving ? "録音中・相手側入力待ち" : state.rawValue
    }
    init() {
        let path = UserDefaults.standard.string(forKey: "destination")
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        let legacy = music.appendingPathComponent("MeetingRecorder", isDirectory: true)
        let initial = FileManager.default.fileExists(atPath: legacy.path) ? legacy : music.appendingPathComponent("Otolog", isDirectory: true)
        destination = path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? initial
        microphoneID = UserDefaults.standard.string(forKey: "microphone") ?? ""
        refresh()
        detector.blocked = { [weak self] in guard let self else { return true }; return self.busy || self.prompt.isVisible }
        detector.detected = { [weak self] candidate in self?.showMeetingPrompt(candidate) }
        detector.inspectWindowTitles = meetingTitlesEnabled
        if detectionEnabled && !CommandLine.arguments.contains("--self-test") { detector.start() }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            connectionObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let connected = note.name == AVCaptureDevice.wasConnectedNotification
                let name = (note.object as? AVCaptureDevice)?.localizedName ?? "音声デバイス"
                Task { @MainActor in
                    guard let self else { return }
                    self.refresh()
                    self.message = "\(name)が\(connected ? "接続" : "切断")されました．入力は自動で変更しません．"
                }
            })
        }
    }
    func refresh() {
        targets = Devices.applications(); microphones = Devices.microphones()
        if microphoneID.isEmpty { microphoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.uniqueID ?? "" }
        recoveries = RecordingStore.recoveries(in: destination)
    }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = destination; panel.prompt = "保存先を選択"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            destination = url; UserDefaults.standard.set(url.path, forKey: "destination"); refresh()
        }
    }
    func start() {
        guard !busy else { return }
        prompt.dismiss()
        let configuration = RecordingConfiguration(mode: mode, bundle: target == "all" ? nil : target, microphoneID: microphoneID, microphoneEnabled: micEnabled, title: recordingName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        state = .starting; playback = configuration.capturesPlayback ? .waiting : .notRequested
        message = nil; elapsed = 0; peaks = [0, 0]; lastFile = nil
        formats = [configuration.capturesPlayback ? "入力待ち" : "録音しません", configuration.capturesMicrophone ? "入力待ち" : "マイク録音オフ"]
        Task { [self] in
            if configuration.capturesMicrophone {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else { message = "マイクの許可がありません．システム設定 → プライバシーとセキュリティ → マイクでOtologを許可してください．"; state = .idle; return }
            }
            do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
            catch { message = "保存先を作成できません：\(error.localizedDescription)"; state = .idle; return }
            UserDefaults.standard.set(configuration.microphoneID, forKey: "microphone")
            let engine = Recorder(); recorder = engine
            engine.progress = { [weak self] p in Task { @MainActor in
                guard let self, self.state == .starting || self.state == .recording else { return }
                self.state = .recording; self.elapsed = p.elapsed; self.peaks = p.peaks; self.formats = p.formats; self.playback = p.playback
            } }
            engine.saving = { [weak self] in Task { @MainActor in self?.state = .saving } }
            engine.completion = { [weak self] file, error in Task { @MainActor in
                guard let self else { return }
                self.recorder = nil; self.peaks = [0, 0]
                await self.completeSave(file: file, issue: error)
            } }
            engine.start(destination: destination, configuration: configuration)
        }
    }
    func stop() { guard state == .recording else { return }; state = .saving; recorder?.stop() }
    func toggleMicrophone(_ value: Bool) {
        guard mode == .meeting else { return }
        if state == .recording && value && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            message = "マイク録音を有効にするには，停止後にマイクの許可を取得して録音を開始してください．"; return
        }
        micEnabled = value
        if state == .recording { recorder?.setMicrophone(value) }
    }
    private func completeSave(file: URL?, issue: String?) async {
        lastFile = file; message = issue
        if let file {
            if askNameOnStop {
                do { lastFile = try await chooseName(for: file) }
                catch { message = [message, "名前を変更できませんでした．既定名の録音は保存済みです：\(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n") }
            }

        }
        state = .idle; refresh()
    }
    private func chooseName(for file: URL) async throws -> URL {
        let panel = NSSavePanel()
        panel.title = "録音の名前を変更して保存"
        panel.message = "キャンセルすると，既定名で保存したファイルを保持します．既存ファイルは上書きできません．"
        panel.directoryURL = file.deletingLastPathComponent()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.canCreateDirectories = true; panel.isExtensionHidden = false
        NSApp.activate(ignoringOtherApps: true)
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return file }
        return try await RecordingStore.moveSavedFile(from: file, to: url)
    }
    func renameLastFile() {
        guard !busy, let file = lastFile else { return }
        state = .saving
        Task {
            do { lastFile = try await chooseName(for: file); message = nil }
            catch { message = "名前を変更できませんでした．元ファイルは保持しています：\(error.localizedDescription)" }
            state = .idle; refresh()
        }
    }
    func setAskName(_ value: Bool) { askNameOnStop = value; UserDefaults.standard.set(value, forKey: "askNameOnStop") }
    func recover(_ url: URL) {
        guard !busy else { return }; state = .saving; message = nil
        Task {
            do {
                let file = try await RecordingStore.finalize(directory: url)
                let issue = FileManager.default.fileExists(atPath: url.path) ? "回復できた音声を保存しました．一部のデータまたは回復フォルダーを保持しています．" : nil
                await completeSave(file: file, issue: issue)
            } catch { message = error.localizedDescription; state = .idle; refresh() }
        }
    }
    func setDetection(_ value: Bool) {
        detectionEnabled = value; UserDefaults.standard.set(value, forKey: "meetingDetectionEnabled")
        if value { detector.start() } else { detector.stop(); prompt.dismiss() }
    }
    func setBrowserTitles(_ value: Bool) {
        meetingTitlesEnabled = value; detector.inspectWindowTitles = value
        UserDefaults.standard.set(value, forKey: "browserTitlesEnabled")
        if value && !AXIsProcessTrusted() {
            MeetingDetector.requestTitleAccess()
            message = "会議名の確認にはアクセシビリティの許可が必要です．未許可でも，マイク利用による会議候補の通知は使えます．"
        }
    }
    private func showMeetingPrompt(_ candidate: MeetingCandidate, preview: Bool = false) {
        guard !busy else { return }
        refresh()
        if !preview { recordingName = candidate.meetingName ?? "" }
        prompt.show(candidate: candidate, microphone: microphoneName, microphoneEnabled: micEnabled, preview: preview) { [weak self] in
            guard let self, !self.busy else { return }
            self.mode = .meeting; self.target = candidate.bundleID; self.start()
        }
    }
    func previewMeetingPrompt() {
        showMeetingPrompt(MeetingCandidate(bundleID: "us.zoom.xos", appName: "Zoom", serviceName: "Zoom", meetingName: "プロダクト定例"), preview: true)
    }
    func showResult() { if let lastFile { NSWorkspace.shared.activateFileViewerSelecting([lastFile]) } }
}
