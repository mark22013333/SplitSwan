// 限時執行外部指令（原本在 DiagnosticRunner，抽出來讓不需要 UI 的程式與測試也能使用）
import Foundation

enum ProcessRunner {
    /// 收集輸出的緩衝區（在 readabilityHandler 的背景執行緒寫入）
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// 執行外部指令，超過 timeout 秒先送 SIGTERM，1 秒後仍在就 SIGKILL。
    /// 輸出用 readabilityHandler 持續讀取，輸出很多也不會因為 pipe 滿了而卡住
    static func runLimited(_ exe: String, _ args: [String], timeout: TimeInterval) async -> DiagnosticReport.CommandResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                let buf = Buffer()
                let eof = DispatchSemaphore(value: 0)
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil; eof.signal() } else { buf.append(d) }
                }
                let exited = DispatchSemaphore(value: 0)
                p.terminationHandler = { _ in exited.signal() }
                do { try p.run() } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(returning: DiagnosticReport.CommandResult(code: 127, output: "無法執行 \(exe)：\(error.localizedDescription)",
                                                                          seconds: timeout))
                    return
                }
                var timedOut = false
                if exited.wait(timeout: .now() + timeout) == .timedOut {
                    timedOut = true
                    p.terminate()
                    if exited.wait(timeout: .now() + 1) == .timedOut {
                        kill(p.processIdentifier, SIGKILL)
                        _ = exited.wait(timeout: .now() + 1)
                    }
                }
                // 等剩下的輸出讀完；子程序若還握著 pipe，最多再等 1 秒
                if eof.wait(timeout: .now() + 1) == .timedOut {
                    pipe.fileHandleForReading.readabilityHandler = nil
                }
                let out = String(decoding: buf.value, as: UTF8.self)
                let code: Int32 = p.isRunning ? -1 : p.terminationStatus
                cont.resume(returning: DiagnosticReport.CommandResult(code: code, output: out, timedOut: timedOut, seconds: timeout))
            }
        }
    }
}
