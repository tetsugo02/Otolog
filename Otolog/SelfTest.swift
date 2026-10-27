import Foundation
import AVFoundation
import CoreAudio

/// Run via the built application executable --self-test. Requires no capture permissions.
enum SelfTest {
    static var renderUISnapshots: Bool { ProcessInfo.processInfo.environment["OTOLOG_SKIP_UI_SNAPSHOTS"] != "1" }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw RecorderError("TEST FAILED: \(message)") }
    }
    static func runAndExit() async {
        do {
            try await run()
            print("PASS: timeline, drift, gaps, mixing, conversion, ALAC segments, export/reload, recovery, microphone mode, meeting detection, JST names, rename safety, meeting titles" + (renderUISnapshots ? ", compact UI" : ""))
            if !renderUISnapshots { print("SKIP: UI snapshots (OTOLOG_SKIP_UI_SNAPSHOTS=1; other self-tests executed)") }
            exit(0)
        }
        catch { fputs("\(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let micOnly = RecordingConfiguration(mode: .microphone, bundle: nil, microphoneID: "test", microphoneEnabled: false)
        try require(micOnly.capturesMicrophone && !micOnly.capturesPlayback, "microphone mode must never require a system tap")
        let playbackOnly = RecordingConfiguration(mode: .meeting, bundle: nil, microphoneID: "test", microphoneEnabled: false)
        try require(playbackOnly.capturesPlayback && !playbackOnly.capturesMicrophone, "playback-only mode")
        let solo = TimelineMixer(epoch: 0, gains: micOnly.gains)
        try solo.place(source: 1, samples: [[0.4, 0.4]], time: 0, duration: 2.0 / 48000)
        let soloAudio = solo.render(frames: 2).0
        try require(abs(soloAudio.floatChannelData![0][0] - 0.4) < 0.0001 && soloAudio.floatChannelData![0][0] == soloAudio.floatChannelData![1][0], "single microphone level and centering")
        let knownDate = ISO8601DateFormatter().date(from: "2026-10-26T18:04:05Z")!
        try require(RecordingNames.baseName(for: knownDate) == "2026-10-27_03-04-05_JST", "JST filename independent of machine timezone")
        try require(MeetingDetectionRules.candidate(bundle: "us.zoom.xos", appName: "Zoom", inputActive: false, windowTitles: []) == nil, "launching Zoom alone is not a meeting")
        let namedTeams = MeetingDetectionRules.candidate(bundle: "com.microsoft.teams2", appName: "Teams", inputActive: true, windowTitles: ["プロダクト定例 | Microsoft Teams"])
        try require(namedTeams?.meetingName == "プロダクト定例", "Teams meeting subject, not the app name")
        let namedMeet = MeetingDetectionRules.candidate(bundle: "com.google.Chrome", appName: "Chrome", inputActive: true, windowTitles: ["設計レビュー - Google Meet - Google Chrome"])
        try require(namedMeet?.meetingName == "設計レビュー", "Meet subject excludes service and browser suffixes")
        let namedZoom = MeetingDetectionRules.candidate(bundle: "us.zoom.xos", appName: "Zoom", inputActive: true, windowTitles: ["Zoom Workplace", "Zoom Meeting - Weekly Sync"])
        try require(namedZoom?.meetingName == "Weekly Sync", "Zoom subject skips generic windows")
        try require(MeetingTitles.name(in: ["Zoom Meeting", "Zoom Workplace"], service: "Zoom", native: true) == nil, "generic app titles are not meeting subjects")
        try require(RecordingNames.baseName(for: knownDate, title: " / : ") == RecordingNames.baseName(for: knownDate), "unsafe empty filenames fall back to JST")
        try require(!RecordingNames.baseName(for: knownDate, title: "開発/定例:Q4").contains("/"), "meeting name cannot escape destination")
        try require(RecordingNames.baseName(for: knownDate, title: "  ") == RecordingNames.baseName(for: knownDate), "empty title falls back to JST")
        try require(RecordingNames.baseName(for: knownDate, title: String(repeating: "会議", count: 120)).utf8.count <= 200, "long Unicode meeting names have bounded filename length")
        let zoom = MeetingDetectionRules.candidate(bundle: "us.zoom.xos", appName: "Zoom", inputActive: true, windowTitles: [])!
        try require(zoom.serviceName == "Zoom", "Zoom active input detection")
        try require(MeetingDetectionRules.candidate(bundle: "com.microsoft.teams2", appName: "Teams", inputActive: true, windowTitles: [])?.serviceName == "Microsoft Teams", "Teams detection")
        try require(MeetingDetectionRules.candidate(bundle: "com.google.Chrome", appName: "Chrome", inputActive: true, windowTitles: ["Meet - abc-defg-hij"])?.serviceName == "Google Meet", "Meet title plus browser input")
        try require(MeetingDetectionRules.candidate(bundle: "com.apple.Safari", appName: "Safari", inputActive: true, windowTitles: [])?.serviceName == nil, "unidentified browser remains a candidate, not a confirmed Meet")
        try require(MeetingDetectionRules.candidate(bundle: "com.example.other", appName: "Other", inputActive: true, windowTitles: ["Google Meet"]) == nil, "unrelated apps are ignored")
        var gate = MeetingNotificationGate()
        try require(gate.update([zoom], now: 0, blocked: false) == nil, "detection debounce first observation")
        try require(gate.update([zoom], now: 3, blocked: false) == zoom, "second observation presents a candidate")
        try require(gate.update([zoom], now: 6, blocked: false) == nil, "no repeated notification within one meeting")
        _ = gate.update([], now: 40, blocked: false)
        try require(gate.update([zoom], now: 43, blocked: false) == nil, "new meeting requires debounce")
        try require(gate.update([zoom], now: 46, blocked: false) == zoom, "new meeting after inactivity")
        var transientGate = MeetingNotificationGate()
        _ = transientGate.update([zoom], now: 0, blocked: false)
        _ = transientGate.update([], now: 3, blocked: false)
        try require(transientGate.update([zoom], now: 6, blocked: false) == nil, "nonconsecutive observations do not notify")
        try require(transientGate.update([zoom], now: 9, blocked: false) == zoom, "consecutive observations after transient input")
        var busyGate = MeetingNotificationGate()
        _ = busyGate.update([zoom], now: 0, blocked: true)
        try require(busyGate.update([zoom], now: 3, blocked: false) == nil, "recording suppresses subsequent duplicate popups")

        let aggregate = ProcessCapture.aggregateConfiguration(tapUID: "test-tap" as CFString)
        try require(aggregate[kAudioAggregateDeviceTapAutoStartKey] as? Bool == false, "aggregate must not wait for playback before starting")
        try require(aggregate[kAudioAggregateDeviceIsPrivateKey] as? Bool == true, "aggregate remains private")
        try require(PlaybackReception.assess(lastPacket: nil, now: 10) == .waiting, "no playback is waiting, not a permission failure")
        try require(PlaybackReception.assess(lastPacket: 9.9, now: 10) == .receiving, "PCM received even when signal is silent")
        try require(PlaybackReception.assess(lastPacket: 1, now: 10) == .inactive, "paused playback is inactive, not a permission failure")

        let mixer = TimelineMixer(epoch: 100)
        try mixer.place(source: 0, samples: [Array(repeating: 1, count: 480)], time: 100.01, duration: 0.01)
        try mixer.place(source: 1, samples: [Array(repeating: 1, count: 480)], time: 100.015, duration: 0.01)
        let rendered = mixer.render(frames: 1440).0
        try require(rendered.floatChannelData![0][0] == 0, "leading silence")
        try require(rendered.floatChannelData![0][500] == 0.5, "source gain")
        try require(rendered.floatChannelData![0][800] == 1, "correlated full scale does not clip")
        try require(rendered.floatChannelData![1][800] == 1, "mono centered")
        try require(rendered.floatChannelData![0][1300] == 0, "trailing silence")
        do {
            try mixer.place(source: 0, samples: [[1]], time: 100.01, duration: 0.01)
            throw RecorderError("TEST FAILED: late packet accepted")
        } catch let error as RecorderError { try require(!error.message.hasPrefix("TEST FAILED"), "late packet detection") }

        let reordered = TimelineMixer(epoch: 100)
        try reordered.place(source: 1, samples: [Array(repeating: 1, count: 480)], time: 100.015, duration: 0.01)
        try reordered.place(source: 0, samples: [Array(repeating: 1, count: 480)], time: 100.01, duration: 0.01)
        let same = reordered.render(frames: 1440).0
        for n in 0..<1440 { try require(same.floatChannelData![0][n] == rendered.floatChannelData![0][n], "independent callback arrival order") }
        let gapMixer = TimelineMixer(epoch: 0)
        let gapStream = StreamNormalizer()
        let gapFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let tone = AVAudioPCMBuffer(pcmFormat: gapFormat, frameCapacity: 480)!
        tone.frameLength = 480
        for i in 0..<480 { tone.floatChannelData![0][i] = 0.5 }
        try gapStream.ingest(tone, time: 0, source: 0, mixer: gapMixer)
        try gapStream.ingest(tone, time: 0.1, source: 0, mixer: gapMixer)
        try gapStream.flush(source: 0, mixer: gapMixer)
        let gapAudio = gapMixer.render(frames: 6000).0
        try require(gapAudio.floatChannelData![0][2000] == 0, "timestamp gap remains silence")
        try require(gapAudio.floatChannelData![0][4900] > 0.2, "audio resumes on original timeline")
        let pausedMixer = TimelineMixer(epoch: 0), pausedStream = StreamNormalizer()
        try pausedStream.ingest(tone, time: 0, source: 0, mixer: pausedMixer)
        try pausedStream.flushIfIdle(before: 0.3, source: 0, mixer: pausedMixer)
        _ = pausedMixer.render(frames: 48000)
        try pausedStream.ingest(tone, time: 2, source: 0, mixer: pausedMixer)
        try pausedStream.flushIfIdle(before: 2.3, source: 0, mixer: pausedMixer)
        let resumed = pausedMixer.render(frames: 48480).0
        try require(resumed.floatChannelData![0][40000] == 0, "long playback pause remains silent")
        try require(resumed.floatChannelData![0][48100] > 0.2, "resume after pause does not reinsert a stale packet")
        let muted = TimelineMixer(epoch: 0)
        try muted.place(source: 0, samples: [Array(repeating: 0.4, count: 480)], time: 0, duration: 0.01)
        try muted.place(source: 1, samples: [Array(repeating: 0.8, count: 480)], time: 0, duration: 0.01)
        muted.clearMicrophone()
        let withoutMic = muted.render(frames: 480).0
        try require(abs(withoutMic.floatChannelData![0][100] - 0.2) < 0.0001, "mic off removes buffered microphone while preserving system audio")
        let stereoMixer = TimelineMixer(epoch: 0), stereoStream = StreamNormalizer()
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let stereo = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 4410)!
        stereo.frameLength = 4410
        for n in 0..<4410 { stereo.floatChannelData![0][n] = 0.4; stereo.floatChannelData![1][n] = -0.2 }
        try stereoStream.ingest(stereo, time: 0, source: 0, mixer: stereoMixer)
        try stereoStream.ingest(stereo, time: 0.1, source: 0, mixer: stereoMixer)
        let stereoOut = stereoMixer.render(frames: 4800).0
        try require(abs(stereoOut.floatChannelData![0][1000] - 0.2) < 0.001, "44.1 kHz stereo conversion left")
        try require(abs(stereoOut.floatChannelData![1][1000] + 0.1) < 0.001, "44.1 kHz stereo conversion right")
        let boundedQueue = DispatchQueue(label: "test.bounded-ingress")
        let ingress = AudioIngress(queue: boundedQueue)
        ingress.setAccepting(true)
        boundedQueue.suspend()
        for _ in 0..<49 { ingress.offer(0, format: gapFormat, list: tone.audioBufferList, frames: 480, time: 0) }
        try require(ingress.takeFault() != nil, "bounded handoff overflow is reported")
        boundedQueue.resume(); boundedQueue.sync {}

        // Synthetic 1-hour clock drift: +100 ppm source clock. Bounded ring and timestamp fitting.
        let drift = TimelineMixer(epoch: 0)
        for n in 0..<36000 {
            let begin = Double(n) * 0.10001
            try drift.place(source: 0, samples: [Array(repeating: 0.25, count: 4800)], time: begin, duration: 0.10001)
            let end = Int(((Double(n + 1) * 0.10001) * 48000).rounded())
            let pcm = drift.render(frames: end - drift.cursor).0
            let minimum = UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)).min() ?? 0
            try require(abs(minimum - 0.125) < 0.0001, "drift continuity including packet endpoints")
        }
        try require(abs(Double(drift.cursor) / 48000 - 3600.36) < 0.0001, "one-hour host timeline")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OtologTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Test artifacts:", root.path)
        if renderUISnapshots {
            try await MeetingPromptController.renderPreview(to: root.appendingPathComponent("meeting-prompt.png"))
            try await RecorderDesignPreview.render(to: root)
        }
        let store = try RecordingStore(destination: root, startedAt: knownDate)
        let manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: store.directory.appendingPathComponent("Recording.json")))
        try require(manifest.startedAt == knownDate, "original recording date persists for recovery")
        let normalizer = StreamNormalizer(), converted = TimelineMixer(epoch: 0)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        // 31 seconds exercises segment rollover, real AVAudioConverter and real ALAC/AAC encoders.
        for n in 0..<310 {
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
            pcm.frameLength = 2400
            for i in 0..<2400 { pcm.floatChannelData![0][i] = 0.4 * sin(Float(n * 2400 + i) * 2 * .pi * 440 / 24000) }
            try normalizer.ingest(pcm, time: Double(n) * 0.1, source: 0, mixer: converted)
            if n > 0 {
                let result = converted.render(frames: 4800).0
                if n == 10 {
                    let level = (0..<4800).map { abs(result.floatChannelData![0][$0]) }.max() ?? 0
                    try require(level > 0.18 && level <= 0.201, "converter level")
                    try require(abs(result.floatChannelData![0][100] - result.floatChannelData![1][100]) < 0.0001, "converted mono stereo")
                }
                try store.append(result)
            }
        }
        try normalizer.flush(source: 0, mixer: converted)
        try store.append(converted.render(frames: 4800).0); store.close()
        try require(RecordingStore.recoveries(in: root).count == 1, "recovery discovery")
        let saved = try await RecordingStore.finalize(directory: store.directory)
        try require(saved.lastPathComponent == "2026-10-27_03-04-05_JST.m4a", "default final recording name")
        let collision = try RecordingNames.uniqueURL(in: root, baseName: "2026-10-27_03-04-05_JST")
        try require(collision.lastPathComponent == "2026-10-27_03-04-05_JST (2).m4a", "timestamp collision receives a suffix")
        let file = try AVAudioFile(forReading: saved)
        try require(file.fileFormat.sampleRate == 48000 && file.fileFormat.channelCount == 2, "saved format")
        try require(file.length == 31 * 48000, "saved duration")
        try require(!FileManager.default.fileExists(atPath: store.directory.path), "cleanup only after verified export")
        file.framePosition = 30 * 48000 - 2400
        let boundary = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800)!
        try file.read(into: boundary, frameCount: 4800)
        for start in stride(from: 0, to: 4800, by: 240) {
            let rms = sqrt((start..<start+240).reduce(Float(0)) { $0 + pow(boundary.floatChannelData![0][$1], 2) } / 240)
            try require(rms > 0.10 && rms < 0.18, "no silence or level jump at segment boundary")
        }
        let occupied = root.appendingPathComponent("occupied.m4a")
        try Data([10, 20, 30]).write(to: occupied)
        var renameRejected = false
        do { _ = try await RecordingStore.moveSavedFile(from: saved, to: occupied) }
        catch { renameRejected = true }
        try require(renameRejected && FileManager.default.fileExists(atPath: saved.path), "rename refuses overwrite and retains original")
        let sentinel = try Data(contentsOf: occupied)
        try require(sentinel == Data([10, 20, 30]), "existing file contents unchanged")
        let renamed = try await RecordingStore.moveSavedFile(from: saved, to: root.appendingPathComponent("renamed-recording.m4a"))
        let renamedFile = try AVAudioFile(forReading: renamed)
        try require(renamedFile.length == 31 * 48000 && !FileManager.default.fileExists(atPath: saved.path), "renamed recording remains readable")
        // Exercise the complete microphone-only path with synthetic native microphone PCM.
        let micStore = try RecordingStore(destination: root, startedAt: knownDate.addingTimeInterval(1), title: "プロダクト定例")
        let micMixer = TimelineMixer(epoch: 0, gains: micOnly.gains), micStream = StreamNormalizer()
        for block in 0..<10 {
            let voice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
            voice.frameLength = 2400
            for i in 0..<2400 { voice.floatChannelData![0][i] = 0.3 * sin(Float(block * 2400 + i) * 2 * .pi * 440 / 24000) }
            try micStream.ingest(voice, time: Double(block) * 0.1, source: 1, mixer: micMixer)
            if block > 0 { try micStore.append(micMixer.render(frames: 4800).0) }
        }
        try micStream.flush(source: 1, mixer: micMixer)
        try micStore.append(micMixer.render(frames: 4800).0); micStore.close()
        let micSaved = try await RecordingStore.finalize(directory: micStore.directory)
        try require(micSaved.lastPathComponent == "プロダクト定例.m4a", "meeting title survives recovery manifest and becomes final filename")
        let namedManifest = try JSONDecoder().decode(RecordingManifest.self, from: JSONEncoder().encode(RecordingManifest(startedAt: knownDate)))
        try require(namedManifest.title == nil, "legacy manifests without a title remain readable")
        let micFile = try AVAudioFile(forReading: micSaved)
        try require(micFile.length == 48000 && micFile.fileFormat.channelCount == 2, "microphone-only AAC format and exact duration")
        let decodedMic = AVAudioPCMBuffer(pcmFormat: micFile.processingFormat, frameCapacity: 8192)!
        try micFile.read(into: decodedMic)
        let micPeak = UnsafeBufferPointer(start: decodedMic.floatChannelData![0], count: Int(decodedMic.frameLength)).map { abs($0) }.max() ?? 0
        try require(micPeak > 0.27 && micPeak < 0.33, "microphone-only file preserves microphone level")
        try require(abs(decodedMic.floatChannelData![0][1000] - decodedMic.floatChannelData![1][1000]) < 0.002, "microphone-only file centered")
        let recovery = try RecordingStore(destination: root)
        let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!, frameCapacity: 4800)!
        pcm.frameLength = 4800
        for c in 0..<2 { for n in 0..<4800 { pcm.floatChannelData![c][n] = 0 } }
        try recovery.append(pcm); recovery.close()
        try Data([0, 1, 2]).write(to: recovery.directory.appendingPathComponent("segment-999999.caf"))
        // Failure to create a final file must preserve every recovery source.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        var saveFailed = false
        do { _ = try await RecordingStore.finalize(directory: recovery.directory) }
        catch { saveFailed = true }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try require(saveFailed, "unwritable destination reports failure")
        try require(FileManager.default.fileExists(atPath: recovery.directory.appendingPathComponent("segment-000000.caf").path), "failed save preserves audio")
        _ = try await RecordingStore.finalize(directory: recovery.directory)
        try require(FileManager.default.fileExists(atPath: recovery.directory.path), "preserve unreadable segments")
    }
}
