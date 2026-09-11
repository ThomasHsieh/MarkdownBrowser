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

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.thomashsieh.markdownbrowser.watch")

    init(url: URL, debounce: TimeInterval = 0.15, onChange: @escaping () -> Void) {
        self.url = url
        self.debounce = debounce
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
