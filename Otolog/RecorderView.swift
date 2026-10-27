import SwiftUI
import AppKit

struct RecorderView: View {
    @ObservedObject var model: AppModel
    @State private var showDetails = false
    private var elapsed: String {
        let seconds = Int(model.elapsed)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    private var waiting: Bool { model.state == .recording && model.mode == .meeting && model.playback != .receiving }
    var body: some View {
        VStack(spacing: 18) {
            header
            VStack(spacing: 5) {
                Text(elapsed).font(.system(size: 40, weight: .light, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(model.busy ? .primary : .secondary)
                Text(model.state == .idle ? "準備ができています" : model.state.rawValue)
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
            Picker("録音モード", selection: $model.mode) {
                Text("会議音声").tag(RecordingMode.meeting)
                Text("マイクのみ").tag(RecordingMode.microphone)
            }.pickerStyle(.segmented).labelsHidden().disabled(model.busy)
            inputs
            VStack(alignment: .leading, spacing: 7) {
                Text("録音名").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    Image(systemName: "pencil.line").foregroundStyle(.tertiary)
                    TextField("日時（JST）で保存", text: $model.recordingName).textFieldStyle(.plain)
                        .font(.system(size: 13)).disabled(model.busy)
                }.padding(11).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }
            if waiting {
                Label("相手側の入力を待っています", systemImage: "clock")
                    .font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    .help(model.playback.message ?? "")
            }
            if let message = model.message { notice(message) }
            Button(action: model.state == .recording ? model.stop : model.start) {
                HStack(spacing: 9) {
                    if model.state == .saving || model.state == .starting {
                        ProgressView().controlSize(.small)
                    } else { Image(systemName: model.state == .recording ? "stop.fill" : "record.circle.fill") }
                    Text(model.state == .recording ? "停止して保存" : model.state == .idle ? "録音を開始" : model.state.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                }.frame(maxWidth: .infinity).frame(height: 42).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.white)
                .background(model.state == .recording ? Color.red : Color.indigo, in: RoundedRectangle(cornerRadius: 10))
                .disabled(model.state == .starting || model.state == .saving)
                .keyboardShortcut("r")
            footer
        }.padding(20).frame(width: 360)
    }
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 22)).foregroundStyle(.indigo)
            Text("Otolog").font(.system(size: 15, weight: .semibold))
            Spacer()
            Circle().fill(model.state == .recording ? Color.red : Color.secondary.opacity(0.35)).frame(width: 5, height: 5)
            Text(model.state == .recording ? "REC" : model.state == .idle ? "待機中" : "処理中")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            SettingsLink { Image(systemName: "gearshape").font(.system(size: 14)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("設定")
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
            Menu {
                Button("一覧を更新", action: model.refresh).disabled(model.busy)
                if !model.recoveries.isEmpty {
                    Menu("未完了の録音を回復") {
                        ForEach(model.recoveries, id: \.self) { url in Button(url.lastPathComponent) { model.recover(url) } }
                    }.disabled(model.busy)
                }
                Divider()
                Button("Otologを終了") { NSApp.terminate(nil) }.disabled(model.busy)
            } label: { Image(systemName: "ellipsis").font(.system(size: 14)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("その他")
        }
    }
    private var inputs: some View {
        VStack(spacing: 12) {
            if model.mode == .meeting {
                HStack(spacing: 9) {
                    Image(systemName: "speaker.wave.2").foregroundStyle(.secondary).frame(width: 16)
                    Text("再生音声").font(.system(size: 12))
                    Spacer(minLength: 0)
                    Menu {
                        Button("Mac全体") { model.target = "all" }
                        ForEach(model.targets) { target in Button(target.name) { model.target = target.id } }
                    } label: {
                        selectionLabel(model.target == "all" ? "Mac全体" : model.targets.first { $0.id == model.target }?.name ?? "未起動のアプリ")
                    }.menuStyle(.borderlessButton).disabled(model.busy)
                }.help("ブラウザーでは他のタブの音声も含む場合があります．")
                level(model.peaks[0], active: true).help(model.formats[0])
                Divider()
            }
            HStack(spacing: 9) {
                Image(systemName: model.recordsMicrophone ? "mic" : "mic.slash").foregroundStyle(.secondary).frame(width: 16)
                Text("マイク").font(.system(size: 12))
                Spacer(minLength: 0)
                Menu {
                    ForEach(model.microphones, id: \.uniqueID) { mic in Button(mic.localizedName) { model.microphoneID = mic.uniqueID } }
                } label: { selectionLabel(model.microphoneName) }
                    .menuStyle(.borderlessButton).disabled(model.busy || !model.recordsMicrophone)
                if model.mode == .meeting {
                    Button { model.toggleMicrophone(!model.micEnabled) } label: {
                        Text(model.micEnabled ? "オン" : "オフ").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(model.micEnabled ? Color.indigo : Color.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(model.micEnabled ? Color.indigo.opacity(0.1) : Color.secondary.opacity(0.1), in: Capsule())
                    }.buttonStyle(.plain).disabled(model.state == .starting || model.state == .saving)
                        .accessibilityLabel("マイク録音 \(model.micEnabled ? "オン" : "オフ")")
                        .help("会議アプリのミュートとは独立したマイク録音スイッチです．")
                }
            }
            level(model.peaks[1], active: model.recordsMicrophone).help(model.formats[1])
            if model.mode == .meeting {
                Text("マイクは会議のミュートと独立").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(13).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private func selectionLabel(_ name: String) -> some View {
        Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: 155, alignment: .trailing)
    }
    private func level(_ value: Float, active: Bool) -> some View {
        let amount = active && value > 0 ? max(0, min(1, (20 * log10(Double(value)) + 60) / 60)) : 0
        return GeometryReader { geometry in
            Capsule().fill(.primary.opacity(0.07))
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.indigo.opacity(0.75)).frame(width: geometry.size.width * amount)
                }
        }.frame(height: 3).accessibilityLabel(active ? "音量 \(Int(amount * 100))パーセント" : "録音オフ")
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: model.lastFile == nil ? "folder" : "checkmark.circle.fill")
                .foregroundStyle(model.lastFile == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                if let file = model.lastFile {
                    Text(file.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                    Text("保存済み").font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("保存先 · \(model.destination.lastPathComponent)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if model.lastFile != nil {
                Button(action: model.renameLastFile) { Image(systemName: "pencil") }.buttonStyle(.plain)
                    .disabled(model.busy).help("保存した録音の名前を変更")
                Button(action: model.showResult) { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.plain).help("Finderで表示")
            }
        }.help(model.lastFile?.path ?? model.destination.path)
    }
    private func notice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Button { showDetails = true } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).help("詳細")
                .popover(isPresented: $showDetails) {
                    ScrollView { Text(message).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                        .frame(width: 320, height: 200)
                }
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("会議の通知") {
                Toggle("会議候補を検知して通知", isOn: Binding(get: { model.detectionEnabled }, set: model.setDetection))
                Toggle("ウインドウから会議名を取得", isOn: Binding(get: { model.meetingTitlesEnabled }, set: model.setBrowserTitles))
                    .disabled(!model.detectionEnabled)
                Text("会議名の取得にはアクセシビリティの許可が必要です．取得できた名前を録音名に使い，取得できない場合はJST日時で保存します．").font(.caption).foregroundStyle(.secondary)
                Button("通知をプレビュー", action: model.previewMeetingPrompt).disabled(model.busy)
            }
            Section("保存") {
                HStack {
                    Text(model.destination.path).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("変更…", action: model.chooseDestination).disabled(model.busy)
                }
                Toggle("停止時に保存名を確認", isOn: Binding(get: { model.askNameOnStop }, set: model.setAskName)).disabled(model.busy)
            }
            Section("音声について") {
                Text("マイク録音は会議のミュートと独立しています．ブラウザーの録音には他タブの音声が含まれる場合があります．").font(.caption)
                Text("AirPodsの通話モードによる音質制約は，保存形式では改善しません．").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 440, height: 450)
    }
}

@MainActor enum RecorderDesignPreview {
    static func render(to directory: URL) throws {
        let model = AppModel()
        model.target = "us.zoom.xos"
        model.targets = [AudioTarget(id: "us.zoom.xos", name: "Zoom")]
        model.recordingName = "プロダクト定例"
        model.destination = URL(fileURLWithPath: "/Users/example/Music/Otolog", isDirectory: true)
        model.message = nil
        try write(RecorderView(model: model), to: directory.appendingPathComponent("panel-idle.png"))
        model.state = .recording; model.playback = .receiving; model.elapsed = 754
        model.peaks = [0.25, 0.08]
        try write(RecorderView(model: model), to: directory.appendingPathComponent("panel-recording.png"))
        model.mode = .microphone; model.state = .idle; model.elapsed = 0; model.recordingName = ""
        try write(RecorderView(model: model), to: directory.appendingPathComponent("panel-microphone.png"))
    }
    private static func write<Content: View>(_ view: Content, to url: URL) throws {
        // Native menus and text fields cannot be drawn by ImageRenderer. Render this
        // app's own view in an unshown window; never capture the desktop or send UI events.
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw RecorderError("パネルのプレビューを描画できません．")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RecorderError("パネルのプレビューを保存できません．")
        }
        window.close()
        try data.write(to: url)
    }
}
