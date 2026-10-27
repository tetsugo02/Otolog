import Foundation
import AVFoundation

/// Lossless 30-second CAF segments are independently readable after a crash.
/// One final AAC encoding avoids AAC priming/remainder accumulating at segment boundaries.
final class RecordingStore {
    let directory: URL
    private var file: AVAudioFile?
    private var segmentFrames: AVAudioFramePosition = 0
    private var index = 0
    static let recoverySettings: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 24]
    static let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000, AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant]
    private static let exportQueue = DispatchQueue(label: "Otolog.final-encoding", qos: .utility)
    init(destination: URL, startedAt: Date = Date(), title: String? = nil) throws {
        directory = destination.appendingPathComponent("\(RecordingNames.baseName(for: startedAt))_\(UUID().uuidString.prefix(8)).recording", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = try JSONEncoder().encode(RecordingManifest(startedAt: startedAt, title: title))
        try manifest.write(to: directory.appendingPathComponent("Recording.json"), options: .atomic)
        try "Otolog recovery v1\n48 kHz stereo 24-bit Apple Lossless CAF; segment order is lexical.\n".write(to: directory.appendingPathComponent("Recovery.txt"), atomically: true, encoding: .utf8)
    }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        if file == nil {
            let url = directory.appendingPathComponent(String(format: "segment-%06d.caf", index))
            file = try AVAudioFile(forWriting: url, settings: Self.recoverySettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            segmentFrames = 0; index += 1
        }
        try file!.write(from: buffer)
        segmentFrames += AVAudioFramePosition(buffer.frameLength)
        if segmentFrames >= 30 * 48000 { file = nil }
    }
    func close() { file = nil }
    static func recoveries(in destination: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "recording" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    static func finalize(directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            exportQueue.async {
                do { continuation.resume(returning: try encode(directory: directory)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    static func moveSavedFile(from source: URL, to destination: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            exportQueue.async {
                do {
                    if source.standardizedFileURL == destination.standardizedFileURL {
                        continuation.resume(returning: source); return
                    }
                    guard destination.pathExtension.lowercased() == "m4a" else { throw RecorderError("保存名の拡張子は.m4aにしてください．") }
                    guard !FileManager.default.fileExists(atPath: destination.path) else { throw RecorderError("同名のファイルが存在します．上書きせず，既定名の録音を保持しています．") }
                    try FileManager.default.moveItem(at: source, to: destination)
                    continuation.resume(returning: destination)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func encode(directory: URL) throws -> URL {
        let parts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "caf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let manifest = (try? Data(contentsOf: directory.appendingPathComponent("Recording.json"))).flatMap { try? JSONDecoder().decode(RecordingManifest.self, from: $0) }
        let name = manifest.map { RecordingNames.baseName(for: $0.startedAt, title: $0.title) } ?? directory.deletingPathExtension().lastPathComponent
        let output = try RecordingNames.uniqueURL(in: directory.deletingLastPathComponent(), baseName: name)
        let staging = directory.appendingPathComponent("finalizing-\(UUID().uuidString).m4a")
        var frames: AVAudioFramePosition = 0
        var expectedFrames: AVAudioFramePosition = 0
        var unreadable: [String] = []
        // Validate every readable source before exporting. A corrupt final open segment may be skipped,
        // but its folder remains and the UI explicitly reports the partial recovery.
        var valid: [URL] = []
        for part in parts {
            do {
                let source = try AVAudioFile(forReading: part, commonFormat: .pcmFormatFloat32, interleaved: false)
                guard source.length > 0, source.fileFormat.sampleRate == 48000, source.fileFormat.channelCount == 2 else { throw RecorderError("回復用音声の形式が不正です．") }
                expectedFrames += source.length
                valid.append(part)
            } catch { unreadable.append(part.lastPathComponent) }
        }
        guard !valid.isEmpty else { throw RecorderError("回復できる音声がありません．回復用データは保持しています：\(directory.path)") }
        do {
            let disk = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
            let available = (disk[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            let needed = expectedFrames / 2 + 20_000_000 // 192 kbps / 48 kHz + container/headroom.
            guard available > needed else { throw RecorderError("完成ファイルの作成に必要な空き容量がありません（目安\(needed / 1_000_000) MB）．空きを確保して回復を再試行してください．") }
            // Scope ensures AAC headers/priming metadata are finalized before verification.
            do {
                let writer = try AVAudioFile(forWriting: staging, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let buffer = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 8192)!
                for part in valid {
                    let source = try AVAudioFile(forReading: part, commonFormat: .pcmFormatFloat32, interleaved: false)
                    while source.framePosition < source.length {
                        try source.read(into: buffer, frameCount: 8192)
                        guard buffer.frameLength > 0 else { throw RecorderError("回復用音声を最後まで読み取れません．") }
                        try writer.write(from: buffer)
                        frames += AVAudioFramePosition(buffer.frameLength)
                    }
                }
            }
            let verify = try AVAudioFile(forReading: staging)
            guard verify.fileFormat.channelCount == 2, verify.fileFormat.sampleRate == 48000,
                  verify.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
                  abs(verify.length - frames) <= 1 else { throw RecorderError("保存ファイルの形式または長さの検証に失敗しました．") }
            // Re-read the complete encoded file before deleting the only recovery sources.
            let buffer = AVAudioPCMBuffer(pcmFormat: verify.processingFormat, frameCapacity: 8192)!
            var decoded: AVAudioFramePosition = 0
            while verify.framePosition < verify.length {
                try verify.read(into: buffer, frameCount: 8192)
                guard buffer.frameLength > 0 else { throw RecorderError("保存ファイルを最後まで再読み込みできません．") }
                decoded += AVAudioFramePosition(buffer.frameLength)
            }
            guard decoded == frames else { throw RecorderError("保存ファイルの読み込みフレーム数が一致しません．") }
            try FileManager.default.moveItem(at: staging, to: output)
            if unreadable.isEmpty {
                // Failure to clean up must not turn a successfully verified recording into a save failure.
                do { try FileManager.default.removeItem(at: directory) }
                catch { try? "保存は完了しました．回復用データの削除はできませんでした．\n完成音声：\(output.path)\n".write(to: directory.appendingPathComponent("Recovery-warning.txt"), atomically: true, encoding: .utf8) }
            } else {
                try "一部の分割音声を読み取れませんでした：\(unreadable.joined(separator: ", "))\n回復できた完成音声：\(output.path)\n".write(to: directory.appendingPathComponent("Recovery-warning.txt"), atomically: true, encoding: .utf8)
            }
            return output
        } catch {
            // Never remove recovery sources on an encoder, disk, or verification failure.
            throw RecorderError("完成ファイルの保存に失敗しました：\(error.localizedDescription)\n回復用データ：\(directory.path)")
        }
    }
}
