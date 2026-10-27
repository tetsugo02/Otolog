import Foundation
import AVFoundation

enum PlaybackReception: Equatable {
    case waiting, receiving, inactive, notRequested
    static func assess(lastPacket: Double?, now: Double) -> Self {
        guard let lastPacket else { return .waiting }
        return now - lastPacket > 1 ? .inactive : .receiving
    }
    var message: String? {
        switch self {
        case .waiting: return "相手側入力待ち：選択した対象の音声データをまだ受信していません．会議や音楽の再生中も続く場合は，対象の選択・取得経路・録音許可を確認してください．"
        case .inactive: return "相手側データ待ち：再生停止中，または取得経路の問題です．マイクの録音設定は独立しています．"
        case .receiving, .notRequested: return nil
        }
    }
}
struct RecordingProgress {
    let elapsed: Double
    let peaks: [Float]
    let formats: [String]
    let playback: PlaybackReception
}
final class Recorder {
    private let queue = DispatchQueue(label: "Otolog.audio-worker", qos: .userInitiated)
    private lazy var ingress = AudioIngress(queue: queue)
    private var tap: ProcessCapture?
    private var microphone: MicrophoneCapture?
    private var mixer: TimelineMixer?
    private var streams = [StreamNormalizer(), StreamNormalizer()]
    private var store: RecordingStore?
    private var timer: DispatchSourceTimer?
    private var running = false
    private var finishing = false
    private var finishIssue: String?
    private var capturesPlayback = true
    private var micEnabled = false
    private var micID = ""
    private var started = 0.0
    private var micStarted = 0.0
    private var lastCheck = 0.0
    var progress: ((RecordingProgress) -> Void)?
    var saving: (() -> Void)?
    var completion: ((URL?, String?) -> Void)?
    func start(destination: URL, configuration: RecordingConfiguration) {
        queue.async { [self] in
            do {
                self.micID = configuration.microphoneID
                self.capturesPlayback = configuration.capturesPlayback
                ingress.receive = { [weak self] source, pcm, time in
                    guard let self, self.running, let mixer = self.mixer, source == 0 || self.micEnabled else { return }
                    do { try self.streams[source].ingest(pcm, time: time, source: source, mixer: mixer) }
                    catch { self.finish(error: error.localizedDescription) }
                }
                store = try RecordingStore(destination: destination, title: configuration.title)
                if configuration.capturesMicrophone { try startMicrophone() }
                if configuration.capturesPlayback {
                    tap = ProcessCapture(ingress)
                    try tap!.start(bundle: configuration.bundle)
                }
                started = hostSeconds(); micStarted = started
                mixer = TimelineMixer(epoch: started, gains: configuration.gains)
                running = true
                ingress.setAccepting(true)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer; timer.resume()
            } catch { finish(error: error.localizedDescription) }
        }
    }
    private func startMicrophone() throws {
        let capture = MicrophoneCapture(ingress)
        microphone = capture
        try capture.start(id: micID)
        micEnabled = true; micStarted = hostSeconds()
    }
    func setMicrophone(_ enabled: Bool) {
        queue.async { [self] in
            guard running, !finishing, enabled != micEnabled else { return }
            do {
                if enabled { try startMicrophone() }
                else { micEnabled = false; microphone?.stop(); microphone = nil }
                streams[1].reset(); mixer?.clearMicrophone()
            } catch { finish(error: error.localizedDescription) }
        }
    }
    func stop() { queue.async { [self] in finish(error: nil) } }
    private func tick() {
        guard running, !finishing, let mixer, let store else { return }
        do {
            if let fault = ingress.takeFault() { throw RecorderError(fault) }
            let now = hostSeconds()
            for source in 0..<2 {
                try streams[source].flushIfIdle(before: now - 0.3, source: source, mixer: mixer)
            }
            let available = max(0, Int(((now - started - 0.6) * 48000).rounded(.down)) - mixer.cursor)
            guard available <= TimelineMixer.capacity else { throw RecorderError("保存処理が遅延しました．回復用データを保持して停止します．") }
            var peaks: [Float] = [0, 0]
            var remaining = available
            while remaining > 0 {
                let count = min(4800, remaining), result = mixer.render(frames: min(4800, remaining))
                try store.append(result.0)
                peaks = zip(peaks, result.1).map { max($0, $1) }
                remaining -= count
            }
            if now - lastCheck > 1 {
                lastCheck = now
                try tap?.refresh()
                if micEnabled { try microphone?.check() }
                if micEnabled && now - max(micStarted, streams[1].latestTime ?? micStarted) > 4 {
                    throw RecorderError("マイクから音声データが届いていません．許可と接続を確認してください．")
                }
                let attributes = try FileManager.default.attributesOfFileSystem(forPath: store.directory.path)
                if (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0 < 100_000_000 { throw RecorderError("保存先の空き容量が100 MB未満です．録音を停止しました．") }
            }
            progress?(RecordingProgress(elapsed: now - started, peaks: peaks, formats: streams.map(\.summary), playback: capturesPlayback ? .assess(lastPacket: streams[0].latestTime, now: now) : .notRequested))
        } catch { finish(error: error.localizedDescription) }
    }
    private func addIssue(_ message: String?) {
        if let message { finishIssue = [finishIssue, message].compactMap { $0 }.joined(separator: "\n") }
    }
    private func finish(error: String?) {
        addIssue(error)
        guard !finishing else { return }
        finishing = true
        let end = hostSeconds()
        ingress.setAccepting(false)
        timer?.cancel(); timer = nil
        saving?()
        tap?.stop(); tap = nil
        microphone?.stop(); microphone = nil
        // Producers are quiescent. Drain their already copied packets before flushing the final packet.
        // This avoids losing callback data that was enqueued while stopRunning/AudioDeviceStop blocked.
        queue.async { [self] in finalizeCapture(end: end) }
    }
    private func finalizeCapture(end: Double) {
        running = false
        if capturesPlayback && mixer != nil && streams[0].latestTime == nil {
            addIssue("相手側の音声データは一度も受信できませんでした．このファイルはマイクのみ，または無音です．許可不足とは断定できません．対象と取得経路を確認してください．")
        }
        addIssue(ingress.takeFault())
        if let mixer, let store {
            for source in 0..<2 {
                do { try streams[source].flush(source: source, mixer: mixer) }
                catch { addIssue(error.localizedDescription) }
            }
            do {
                var remaining = max(0, Int((end - started) * 48000) - mixer.cursor)
                if remaining > TimelineMixer.capacity {
                    addIssue("末尾の時刻差が大きいため，保持できたデータから保存します．")
                    remaining = TimelineMixer.capacity
                }
                while remaining > 0 {
                    let count = min(4800, remaining)
                    try store.append(mixer.render(frames: count).0); remaining -= count
                }
            } catch { addIssue(error.localizedDescription) }
        }
        store?.close()
        guard let directory = store?.directory else { completion?(nil, finishIssue); return }
        store = nil
        let reason = finishIssue
        Task { [self] in
            do {
                let result = try await RecordingStore.finalize(directory: directory)
                let warning = FileManager.default.fileExists(atPath: directory.appendingPathComponent("Recovery-warning.txt").path) ? "一部回復または回復フォルダーの削除失敗があります．詳細と元データは回復フォルダーに保持しています．" : nil
                completion?(result, [reason, warning].compactMap { $0 }.joined(separator: "\n").nilIfEmpty)
            } catch { completion?(nil, [reason, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")) }
        }
    }
}
extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
