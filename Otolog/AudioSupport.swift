import Foundation
import Synchronization
import AppKit
import CoreAudio
import AVFoundation

struct RecorderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
func checked(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else { throw RecorderError("\(action)に失敗しました（Core Audio: \(status)）．システム設定の録音許可とデバイス接続を確認してください．") }
}
func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
    var a = address(selector), value = initial, size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    try checked(status, "音声情報の取得")
    return value
}
func objectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = address(selector), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    guard size > 0, size.isMultiple(of: UInt32(MemoryLayout<AudioObjectID>.size)) else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    let result = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, $0.baseAddress!) }
    return result == noErr ? ids : []
}
struct AudioTarget: Identifiable, Hashable {
    let id: String
    let name: String
}
enum Devices {
    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    static func applications() -> [AudioTarget] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundle = app.bundleIdentifier, app.activationPolicy == .regular,
                  bundle != Bundle.main.bundleIdentifier else { return nil }
            return AudioTarget(id: bundle, name: app.localizedName ?? bundle)
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
    // Include helper processes by bundle family AND the enclosing application bundle path.
    static func processes(for bundle: String) -> [AudioObjectID] {
        let appURL = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundle }?.bundleURL
        return objectList(kAudioHardwarePropertyProcessObjectList).filter { id in
            let bid = (try? property(id, kAudioProcessPropertyBundleID, initial: "" as CFString)) as String? ?? ""
            if bid == bundle || bid.hasPrefix(bundle + ".") { return true }
            let pid = try? property(id, kAudioProcessPropertyPID, initial: pid_t(0))
            guard let pid, let path = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path, let root = appURL?.path else { return false }
            return path == root || path.hasPrefix(root + "/")
        }
    }
}
func hostSeconds() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

/// Bounded callback handoff. Callbacks only copy native PCM; conversion, metering and I/O run on worker.
final class AudioIngress {
    let queue: DispatchQueue
    private let capacity = DispatchSemaphore(value: 48)
    private let accepting = Atomic<Bool>(false)
    func setAccepting(_ value: Bool) { accepting.store(value, ordering: .releasing) }
    private let faultLock = NSLock()
    private var fault: String?
    var receive: ((Int, AVAudioPCMBuffer, Double) -> Void)?
    init(queue: DispatchQueue) { self.queue = queue }
    func fail(_ message: String) { faultLock.lock(); if fault == nil { fault = message }; faultLock.unlock() }
    func takeFault() -> String? { faultLock.lock(); defer { faultLock.unlock() }; let value = fault; fault = nil; return value }
    func offer(_ source: Int, format: AVAudioFormat, list: UnsafePointer<AudioBufferList>, frames: UInt32, time: Double) {
        guard accepting.load(ordering: .acquiring) else { return }
        guard frames > 0, frames <= 16384, format.channelCount <= 8 else { fail("入力バッファーが対応範囲を超えました．"); return }
        guard capacity.wait(timeout: .now()) == .success else { fail("音声処理が追いつきません．回復用データを保持して停止します．"); return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { capacity.signal(); fail("音声バッファーを確保できません．"); return }
        copy.frameLength = frames
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard src.count == dst.count else { capacity.signal(); fail("入力の音声形式が変更されました．"); return }
        for i in src.indices {
            guard let from = src[i].mData, let to = dst[i].mData, src[i].mDataByteSize <= dst[i].mDataByteSize else { capacity.signal(); fail("入力の音声形式が変更されました．"); return }
            memcpy(to, from, Int(src[i].mDataByteSize))
        }
        queue.async { [self] in defer { capacity.signal() }; receive?(source, copy, time) }
    }
}
