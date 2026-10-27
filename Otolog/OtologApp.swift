import SwiftUI
import AppKit

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy == true {
            let alert = NSAlert()
            alert.messageText = "録音または保存処理が進行中です"
            alert.informativeText = "録音を停止し，保存完了を確認してから終了してください．"
            alert.addButton(withTitle: "アプリに戻る"); alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
}
@main struct OtologApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var model: AppModel
    init() {
        let value = AppModel()
        _model = StateObject(wrappedValue: value)
        delegate.model = value
        if CommandLine.arguments.contains("--self-test") {
            Task { await SelfTest.runAndExit() }
        }
    }
    var body: some Scene {
        MenuBarExtra {
            RecorderView(model: model).onAppear { delegate.model = model; model.refresh() }
        } label: {
            Image(systemName: model.busy ? "record.circle.fill" : "waveform.circle")
                .accessibilityLabel("Otolog \(model.state.rawValue)")
        }.menuBarExtraStyle(.window)
        Settings { PreferencesView(model: model) }
    }
}
