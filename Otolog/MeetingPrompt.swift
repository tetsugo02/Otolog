import AppKit
import SwiftUI

private final class MeetingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor final class MeetingPromptController {
    private var panel: NSPanel?
    private var expiry: Timer?
    var isVisible: Bool { panel?.isVisible ?? false }
    func show(candidate: MeetingCandidate, microphone: String, microphoneEnabled: Bool, preview: Bool = false, start: @escaping () -> Void) {
        dismiss()
        let panel = MeetingPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 280), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let view = MeetingPromptView(candidate: candidate, microphone: microphone, microphoneEnabled: microphoneEnabled, preview: preview, start: { [weak self] in
            self?.dismiss(); start()
        }, dismiss: { [weak self] in self?.dismiss() })
        panel.contentView = NSHostingView(rootView: view)
        if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 396, y: frame.maxY - 300))
        }
        self.panel = panel
        panel.orderFrontRegardless() // Show without taking keyboard focus from the meeting.
        expiry = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }
    static func renderPreview(to url: URL) throws {
        let candidate = MeetingCandidate(bundleID: "us.zoom.xos", appName: "Zoom", serviceName: "Zoom", meetingName: "プロダクト定例")
        let content = MeetingPromptView(candidate: candidate, microphone: "Mac内蔵マイク", microphoneEnabled: true, preview: false, start: {}, dismiss: {})
            .environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw RecorderError("通知プレビューを描画できません．")
        }
        try data.write(to: url)
    }
    func dismiss() { expiry?.invalidate(); expiry = nil; panel?.orderOut(nil); panel = nil }
}
private struct MeetingPromptView: View {
    let candidate: MeetingCandidate
    let microphone: String
    let microphoneEnabled: Bool
    let preview: Bool
    let start: () -> Void
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 30)).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Otolog").font(.headline)
                    Text(preview ? "通知のプレビュー" : "会議候補を検知しました").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("閉じる")
            }
            Text(candidate.meetingName ?? "\(candidate.title)を録音しますか？").font(.title3.weight(.semibold)).lineLimit(2)
            Text(candidate.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(microphoneEnabled ? "マイク：\(microphone)・録音オン" : "マイク録音オフ・再生音声のみ").font(.caption)
            Text("ボタンを押すまで録音しません．マイク録音は会議のミュートと独立しています．").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("今はしない", action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button(preview ? "閉じる（プレビュー）" : "録音開始", action: preview ? dismiss : start)
                    .buttonStyle(.borderedProminent).tint(.indigo)
            }
        }.padding(20).frame(width: 380, height: 280).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
