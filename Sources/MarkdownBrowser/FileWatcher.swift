import Foundation

/// 監聽單一檔案或資料夾的變更。
///
/// 編輯器多半是「寫暫存檔再 rename 蓋過去」，所以收到 `.rename` / `.delete`
/// 之後舊的 fd 已經指向被換掉的 inode，必須重新開檔重新掛監聽，
/// 否則只會收到第一次事件然後永遠安靜。
final class FileWatcher {

    private let url: URL
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private let onRename: ((URL) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.thomashsieh.markdownbrowser.watch")

    /// `onRename` 給了的話，檔案被真的改名（`mv`、`git mv`）時會帶著新路徑呼叫，
    /// 而且不再重掛監聽 —— 由呼叫端決定要不要跟過去。
    init(url: URL, debounce: TimeInterval = 0.15,
         onRename: ((URL) -> Void)? = nil,
         onChange: @escaping () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onRename = onRename
        self.onChange = onChange
        start()
    }

    deinit { stop() }

    private func start() {
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            // 檔案可能正在被換掉，稍後再試一次。
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.start() }
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            // 不聽 .attrib：讀檔本身就會更新 atime，聽了會變成「讀→事件→再讀」的迴圈。
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.rename), self.onRename != nil {
                // 趁 fd 還開著問出它現在的路徑。重掛監聽之後 fd 就關了，再也問不到。
                self.handleRename(newPath: Self.currentPath(of: self.fileDescriptor))
                return
            }
            self.schedule()
            if flags.contains(.rename) || flags.contains(.delete) {
                self.rearm()
            }
        }

        src.setCancelHandler { [fd = fileDescriptor] in
            if fd >= 0 { close(fd) }
        }

        source = src
        src.resume()
    }

    /// 真的改名，還是編輯器的原子存檔？
    ///
    /// 編輯器「寫暫存檔再 rename 蓋過去」時，舊路徑馬上又會出現；有些編輯器還會先把
    /// 原檔 rename 成備份（`X.md~`），這時 fd 問到的是備份的路徑。所以晚一點回頭看：
    /// 舊路徑又出現了就當一般的修改，沒出現而新路徑存在才是改名。
    private func handleRename(newPath: String?) {
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            if !fm.fileExists(atPath: self.url.path),
               let newPath, newPath != self.url.path, fm.fileExists(atPath: newPath),
               !Self.isInTrash(newPath) {
                self.stop()
                let target = URL(fileURLWithPath: newPath)
                DispatchQueue.main.async { self.onRename?(target) }
            } else {
                self.schedule()
                self.rearm()
            }
        }
    }

    /// 丟進垃圾桶在檔案系統上也是一次 rename，fd 問到的會是垃圾桶裡的路徑。
    /// 那是刪除不是改名：跟過去的話，sidecar 會被一起搬進垃圾桶。
    private static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }

    private static func currentPath(of fd: CInt) -> String? {
        guard fd >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }

    private func rearm() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.start() }
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onChange() }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func stop() {
        pending?.cancel()
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }
}
