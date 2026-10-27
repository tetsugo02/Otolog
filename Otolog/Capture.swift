import Foundation
import AVFoundation
import CoreAudio

final class ProcessCapture {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private var description: CATapDescription?
    private var format: AVAudioFormat?
    private var selectedBundle: String?
    private var processIDs: [AudioObjectID] = []
    private let ingress: AudioIngress
    init(_ ingress: AudioIngress) { self.ingress = ingress }
    func start(bundle: String?) throws {
        selectedBundle = bundle
        processIDs = bundle.map(Devices.processes(for:)) ?? []
        guard bundle == nil || !processIDs.isEmpty else { throw RecorderError("対象アプリの音声プロセスが見つかりません．会議に参加して音声再生後に再試行するか，Mac全体を選択してください．") }
        let d = bundle == nil ? CATapDescription(stereoGlobalTapButExcludeProcesses: []) : CATapDescription(stereoMixdownOfProcesses: processIDs)
        d.name = "Otolog capture"
        d.isPrivate = true
        d.muteBehavior = .unmuted
        description = d
        do {
            try checked(AudioHardwareCreateProcessTap(d, &tap), "再生音声Tapの作成")
            let asbd = try property(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            var mutable = asbd
            guard let fmt = AVAudioFormat(streamDescription: &mutable) else { throw RecorderError("Tap音声形式を読み取れません．") }
            format = fmt
            let uid = try property(tap, kAudioTapPropertyUID, initial: "" as CFString)
            let spec = Self.aggregateConfiguration(tapUID: uid)
            try checked(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate), "専用入力の作成")
            let sink = ingress
            try checked(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, stamp, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = buffers.first, fmt.streamDescription.pointee.mBytesPerFrame > 0 else { return }
                let count = first.mDataByteSize / fmt.streamDescription.pointee.mBytesPerFrame
                guard count > 0 else { return }
                guard stamp.pointee.mFlags.contains(.hostTimeValid) else { sink.fail("再生音声の時刻情報がありません．"); return }
                sink.offer(0, format: fmt, list: input, frames: count, time: AVAudioTime.seconds(forHostTime: stamp.pointee.mHostTime))
            }, "音声コールバックの作成")
            try checked(AudioDeviceStart(aggregate, proc), "再生音声録音の開始")
        } catch { stop(); throw error }
    }
    static func aggregateConfiguration(tapUID: CFString) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "Otolog Private Input",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            // true means WAIT for a tapped application's first audio, rather than
            // "start the tap automatically". Run immediately, including during silence.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
        ]
    }
    func refresh() throws {
        guard let bundle = selectedBundle, let description, tap != 0 else { return }
        let ids = Devices.processes(for: bundle)
        guard !ids.isEmpty else { throw RecorderError("対象アプリの音声プロセスが終了しました．録音を停止します．") }
        if Set(ids) != Set(processIDs) {
            description.processes = ids
            var a = address(kAudioTapPropertyDescription)
            var value: CATapDescription = description
            let status = withUnsafePointer(to: &value) { AudioObjectSetPropertyData(tap, &a, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0) }
            try checked(status, "対象プロセスの更新")
            processIDs = ids
        }
        let asbd = try property(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        if let format, (asbd.mSampleRate != format.sampleRate || asbd.mChannelsPerFrame != format.channelCount) {
            throw RecorderError("出力デバイスの音声形式が変わりました．録音を停止しました．接続を確認して再開してください．")
        }
    }
    func stop() {
        if aggregate != 0, let proc { AudioDeviceStop(aggregate, proc); AudioDeviceDestroyIOProcID(aggregate, proc) }
        proc = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        description = nil
    }
    deinit { stop() }
}

final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let callback = DispatchQueue(label: "Otolog.microphone")
    private let ingress: AudioIngress
    private var observations: [NSObjectProtocol] = []
    private var device: AVCaptureDevice?
    init(_ ingress: AudioIngress) { self.ingress = ingress }
    func start(id: String) throws {
        guard let device = Devices.microphones().first(where: { $0.uniqueID == id }), device.isConnected else { throw RecorderError("選択したマイクが接続されていません．別のマイクへは自動で切り替えません．") }
        self.device = device
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: callback)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); throw RecorderError("選択したマイクを録音に使用できません．") }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        let center = NotificationCenter.default
        observations.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in self?.ingress.fail("選択したマイクが切断されました．再接続後に録音を再開してください．") })
        observations.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            self?.ingress.fail("マイク録音でエラーが発生しました：\((note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "不明なエラー")")
        })
        session.startRunning()
        guard session.isRunning else { throw RecorderError("マイク録音を開始できません．マイクの許可と接続を確認してください．") }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let clock = session.synchronizationClock else { ingress.fail("マイクの形式または基準時計を取得できません．"); return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: clock, to: CMClockGetHostTimeClock())
        let time = CMTimeGetSeconds(pts)
        guard time.isFinite else { ingress.fail("マイクの時刻情報が不正です．"); return }
        var required = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &required, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard required <= 4096 else { ingress.fail("マイクのチャンネル数が対応範囲を超えました．"); return }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: required, alignment: 16)
        defer { memory.deallocate() }
        var block: CMBlockBuffer?
        let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: required, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &block)
        guard status == noErr else { ingress.fail("マイク音声を読み取れません．"); return }
        ingress.offer(1, format: format, list: UnsafePointer(list), frames: UInt32(CMSampleBufferGetNumSamples(sampleBuffer)), time: time)
    }
    func check() throws {
        guard device?.isConnected == true, session.isRunning else { throw RecorderError("選択したマイクの接続が失われました．") }
    }
    func stop() {
        session.stopRunning()
        callback.sync {}
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        device = nil
    }
    deinit { stop() }
}
