import AppKit
import SwiftUI

/// 一個視窗的根視圖。
///
/// `WindowGroup` 刻意不帶值（見 `WindowRouter.handoffs`），所以「這個視窗要讀
/// 哪個檔」是開窗時由 router 交棒過來的，不是 SwiftUI 的視窗值。
struct DocumentWindow: View {

    /// 一個視窗一份。`@StateObject` 在每個視窗各自建立，不再是共用的單例。
    @StateObject private var state = DocumentState()

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(state: state, settings: settings)
            .background(WindowAccessor { window in
                WindowRouter.shared.attach(state, to: window)
            })
            .onAppear {
                let router = WindowRouter.shared
                router.openWindow = openWindow
                router.register(state)
                if state.documentURL == nil, let url = router.takeHandoff() { state.open(url) }
            }
    }
}

/// 取得 SwiftUI 視窗底下的 `NSWindow`。
///
/// 多視窗之後要靠它認出哪個視窗在前景、哪個視窗關了，還有把強制的
/// 淺色／深色設到視窗上。SwiftUI 沒有等價的 API，而選單與按鍵監聽都在
/// SwiftUI 的 focus 環境之外。
struct WindowAccessor: NSViewRepresentable {

    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// 用 `viewDidMoveToWindow` 而不是在 `updateNSView` 裡輪詢 —— 掛上視窗的
    /// 那一刻剛好會呼叫這個方法，時機精準而且只會來一次。
    private final class ReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
