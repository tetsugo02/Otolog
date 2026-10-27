import Foundation
import AVFoundation

/// Fixed 4-second ring on a 48 kHz host-time axis. All access belongs to the worker queue.
final class TimelineMixer {
    static let rate = 48_000.0
    static let capacity = 192_000
    let epoch: Double
    private(set) var cursor = 0
    private var lanes = Array(repeating: Array(repeating: Float(0), count: capacity * 2), count: 2)
    private let gains: [Float]
    init(epoch: Double, gains: [Float] = [0.5, 0.5]) {
        precondition(gains.count == 2 && gains.allSatisfy { $0 >= 0 && $0 <= 1 })
        self.epoch = epoch; self.gains = gains
    }
    func clearMicrophone() { lanes[1] = Array(repeating: 0, count: Self.capacity * 2) }
    func place(source: Int, samples: [[Float]], time: Double, duration: Double) throws {
        guard time.isFinite, duration.isFinite, duration > 0, samples.count >= 1, !samples[0].isEmpty else { return }
        guard abs(time - epoch) < 604800, duration <= 4 else { throw RecorderError("入力音声の時刻が対応範囲を超えました．") }
        let start = Int(((time - epoch) * Self.rate).rounded())
        // Round absolute endpoints, not each packet duration, so fractional frames do not
        // become periodic one-frame gaps/overlaps as independent device clocks drift.
        let end = Int(((time + duration - epoch) * Self.rate).rounded())
        let count = max(1, end - start)
        guard count <= Self.capacity, start + count <= cursor + Self.capacity else { throw RecorderError("音声の時刻差がバッファー上限を超えました．") }
        guard start >= cursor || (start < 0 && cursor == 0) else { throw RecorderError("音声が遅延し，時刻同期を維持できません．保存済みデータを保持して停止します．") }
        for n in 0..<count {
            let frame = start + n
            if frame < 0 { continue }
            let position = Double(n) * Double(samples[0].count) / Double(count)
            let lo = min(samples[0].count - 1, Int(position)), hi = min(samples[0].count - 1, lo + 1)
            let fraction = Float(position - Double(lo))
            for channel in 0..<2 {
                let values = samples[min(channel, samples.count - 1)]
                lanes[source][(frame % Self.capacity) * 2 + channel] = values[lo] + (values[hi] - values[lo]) * fraction
            }
        }
    }
    func render(frames: Int) -> (AVAudioPCMBuffer, [Float]) {
        precondition(frames > 0 && frames <= Self.capacity)
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
        out.frameLength = UInt32(frames)
        var peaks: [Float] = [0, 0]
        for n in 0..<frames {
            let slot = ((cursor + n) % Self.capacity) * 2
            for c in 0..<2 {
                let a = lanes[0][slot + c], b = lanes[1][slot + c]
                peaks[0] = max(peaks[0], abs(a)); peaks[1] = max(peaks[1], abs(b))
                // Meeting mode reserves -6 dB per source; microphone-only mode preserves its level.
                let mixed = a * gains[0] + b * gains[1]
                out.floatChannelData![c][n] = mixed.isFinite ? min(1, max(-1, mixed)) : 0
                lanes[0][slot + c] = 0; lanes[1][slot + c] = 0
            }
        }
        cursor += frames
        return (out, peaks)
    }
}

final class StreamNormalizer {
    struct Packet { let samples: [[Float]]; let time: Double; let duration: Double }
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var pending: Packet?
    private(set) var latestTime: Double?
    private(set) var summary = "入力待ち"
    func ingest(_ pcm: AVAudioPCMBuffer, time: Double, source: Int, mixer: TimelineMixer) throws {
        if inputFormat != pcm.format {
            try flush(source: source, mixer: mixer)
            let output = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: min(2, pcm.format.channelCount))!
            guard let converter = AVAudioConverter(from: pcm.format, to: output) else { throw RecorderError("入力音声の形式変換に対応していません．") }
            converter.primeMethod = .none
            self.converter = converter; inputFormat = pcm.format
            summary = "\(Int(pcm.format.sampleRate)) Hz / \(pcm.format.channelCount) ch → 48 kHz"
        }
        guard let converter else { return }
        let capacity = UInt32(ceil(Double(pcm.frameLength) * 48000 / pcm.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { throw RecorderError("形式変換バッファーを確保できません．") }
        var delivered = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if delivered { state.pointee = .noDataNow; return nil }
            delivered = true; state.pointee = .haveData; return pcm
        }
        guard status != .error, error == nil else { throw error ?? RecorderError("音声変換に失敗しました．") as NSError }
        let count = Int(output.frameLength)
        guard count > 0 else { return }
        let samples = (0..<Int(output.format.channelCount)).map { Array(UnsafeBufferPointer(start: output.floatChannelData![$0], count: count)) }
        let next = Packet(samples: samples, time: time, duration: Double(count) / 48000)
        if let prior = pending {
            let delta = time - prior.time
            guard delta > 0 else { throw RecorderError("入力音声の時刻が逆転しました．") }
            // Fit to hardware timestamps, compensating slow clock drift independently for each source.
            // A large timestamp gap is actual missing audio and remains silent.
            let duration = abs(delta - prior.duration) < prior.duration * 0.1 ? delta : min(delta, prior.duration)
            try mixer.place(source: source, samples: prior.samples, time: prior.time, duration: duration)
        }
        pending = next; latestTime = time
    }
    func flushIfIdle(before time: Double, source: Int, mixer: TimelineMixer) throws {
        // A paused system stream may not send another callback. Commit its last packet
        // before the renderer advances, so resuming after a long pause cannot place it late.
        if let pending, pending.time + pending.duration < time {
            try flush(source: source, mixer: mixer)
        }
    }
    func flush(source: Int, mixer: TimelineMixer) throws {
        if let pending { try mixer.place(source: source, samples: pending.samples, time: pending.time, duration: pending.duration) }
        pending = nil
    }
    func reset() { pending = nil; converter = nil; inputFormat = nil; latestTime = nil }
}
