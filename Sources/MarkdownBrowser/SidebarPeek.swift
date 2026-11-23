import SwiftUI
import AppKit
import WebKit

/// 側欄收攏時，游標碰視窗左緣浮出側欄（docs/SPEC.md 5.3）。
///
/// 浮在內容上方而不是推開內容：內容區一變窄，書要整本重新分頁、心得重新斷行，
/// 滑鼠只是經過左緣，畫面就整片跳一次。數字是在實機 prototype 比過定的
///（分支 prototype/hover-sidebar）：觸發 16 px 不延遲，收回寬限 300 ms ——
/// 250 ms 時手晃出邊界、還沒拉回來就收掉了。
struct SidebarPeek: View {

    @ObservedObject var state: DocumentState

    private static let edgeWidth: CGFloat = 16
    private static let hideGrace = 0.3

    @State private var shown = false
    @State private var inEdge = false
    @State private var inPanel = false
    @State private var menuOpen = false
    @State private var hideWork: DispatchWorkItem?
    /// 側欄在視窗裡的位置。右鍵選單關掉時 hover 狀態不可靠（選單追蹤期間收不到進出），
    /// 要拿游標位置自己比
    @State private var panelFrame: CGRect = .zero
    /// 整個浮出層（＝內容區）的位置，用來換算左緣觸發區
    @State private var areaFrame: CGRect = .zero

    var body: some View {
        ZStack(alignment: .leading) {
            // 浮出時側欄從 x = 6 開始，最左邊那幾 px 的觸發區仍露在外面，
            // 收回倒數中游標退回這裡也算「還在」
            Color.clear
                .frame(width: Self.edgeWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { inEdge = $0; update() }

            if shown {
                Sidebar(state: state)
                    .environment(\.sidebarPicked, { dismiss() })
                    .frame(width: state.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.35), radius: 12, x: 2, y: 0)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panelFrame = $0 }
                    .onHover { inPanel = $0; update() }
                    .padding(.vertical, 8)
                    .padding(.leading, 6)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { areaFrame = $0 }
        .animation(.easeOut(duration: 0.15), value: shown)
        // 側欄裡的右鍵選單是另一個視窗，游標移到選單上對側欄來說就是「離開」。
        // 開著時不收，關掉後看游標在不在側欄裡再決定。
        // 選單通知是全 App 的，選單列、工具列的選單、網頁自己的右鍵選單都會發；SwiftUI 的
        // .contextMenu 又認不出是哪一個 NSMenu。右鍵選單開在游標所在處，所以開始追蹤的那一刻
        // 游標在側欄裡，才算側欄的選單
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            guard shown, let p = mousePoint(), panelFrame.contains(p) else { return }
            menuOpen = true
            cancelHide()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            guard menuOpen else { return }
            menuOpen = false
            // 選單追蹤期間收不到進出，兩個旗標都是選單打開前的舊值
            let p = mousePoint()
            inPanel = p.map { panelFrame.contains($0) } ?? false
            inEdge = p.map { edgeFrame.contains($0) } ?? false
            update()
        }
        .onDisappear { cancelHide() }
    }

    /// 進出觸發區與側欄的事件順序不保證（先進後出或先出後進都可能），
    /// 所以每次都看兩個旗標重新決定，不在單一事件裡下結論
    private func update() {
        if inEdge || inPanel {
            cancelHide()
            // 選字拖到左緣不算：按著滑鼠鍵就不浮出
            if !shown, inEdge, NSEvent.pressedMouseButtons == 0 { shown = true }
        } else if shown, !menuOpen, hideWork == nil {
            let work = DispatchWorkItem { dismiss() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideGrace, execute: work)
        }
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    /// 收起來。點了一列也走這裡：浮出是「瞄一眼、跳過去」，游標還在側欄上也不留著擋住剛跳到的內文
    private func dismiss() {
        cancelHide()
        // 側欄拿掉時不一定收得到 hover 結束，不清掉的話下次碰左緣會以為游標還在側欄裡
        inPanel = false
        shown = false
        restoreFocus()
    }

    /// 點側欄的列可能讓 List 拿走 first responder。側欄收起來之後還留在它身上，
    /// 方向鍵就送到看不見的清單。換檔那條路自己會交焦點，這裡只在不在網頁上時才交
    private func restoreFocus() {
        DispatchQueue.main.async {
            guard let window = state.window else { return }
            var view = window.firstResponder as? NSView
            while let v = view {
                if v is WKWebView { return }
                view = v.superview
            }
            state.focusedBridge?.takeFocus()
        }
    }

    private var edgeFrame: CGRect {
        CGRect(x: areaFrame.minX, y: areaFrame.minY, width: Self.edgeWidth, height: areaFrame.height)
    }

    /// 游標在 SwiftUI global 座標（contentView 左上為原點）的位置
    private func mousePoint() -> CGPoint? {
        guard let window = state.window, let content = window.contentView else { return nil }
        // 不假設 contentView 跟視窗一樣高：沒有 fullSizeContentView 時會差一個標題列加工具列
        var p = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !content.isFlipped { p.y = content.bounds.height - p.y }
        return p
    }
}

/// 點了側欄的一列。浮出的側欄掛上「收起來」；固定的側欄沒掛，什麼都不做。
private struct SidebarPickedKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var sidebarPicked: () -> Void {
        get { self[SidebarPickedKey.self] }
        set { self[SidebarPickedKey.self] = newValue }
    }
}
