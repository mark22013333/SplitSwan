// 連線紀錄：在 App 內顯示 strongSwan 的即時 log（取代另開終端機），
// 並把 App 自己的動作（連線、重試、重建通道）一起記進來。只保留最近 1,000 行。
import Foundation
import Combine

@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    struct Line: Identifiable, Equatable {
        let id: Int
        let time: Date
        let text: String
        let fromApp: Bool   // true：App 自己的動作；false：strongSwan 的 log
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var streaming = false
    private var nextID = 0
    private var process: Process?
    private var buffer = Data()
    private let maxLines = 1000

    /// App 自己的動作
    func app(_ text: String) {
        append(text, fromApp: true)
    }

    func clear() { lines.removeAll() }

    /// App 結束時停止串流，避免 swanctl --log 留在背景
    func stop() {
        guard let p = process else { return }
        p.terminationHandler = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        p.terminate()
        process = nil
        streaming = false
    }

    var allText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return lines.map { "\(f.string(from: $0.time)) \($0.fromApp ? "[App] " : "")\($0.text)" }.joined(separator: "\n")
    }

    /// 開始讀取 strongSwan 的即時 log（輔助程式 `log` 子命令）。中斷就 5 秒後重接
    func startStreaming() {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", helperPath, "log"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.streaming = false
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.startStreaming()
            }
        }
        do {
            try p.run()
            process = p
            streaming = true
        } catch {
            app("無法讀取 strongSwan log：\(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            let text = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { append(text, fromApp: false) }
        }
    }

    private func append(_ text: String, fromApp: Bool) {
        lines.append(Line(id: nextID, time: Date(), text: text, fromApp: fromApp))
        nextID += 1
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }
}
