// 限時執行外部指令（原本在 DiagnosticRunner，抽出來讓不需要 UI 的程式與測試也能使用）。
// 診斷、主機檢查、一鍵更新走 runLimited；VPNController 呼叫輔助程式走 execute，
// 全 App 只有這裡一份「逾時 → SIGTERM → 寬限後 SIGKILL」的實作
import Foundation

enum ProcessRunner {
    /// 收集輸出的緩衝區（在 readabilityHandler 的背景執行緒寫入）
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// execute 的結果。output 是原始輸出（未修剪）；launchError 不為 nil 代表執行檔根本沒跑起來（此時 code 為 127）
    struct Outcome: Equatable {
        var code: Int32
        var output: String
        var timedOut: Bool
        var launchError: String?
    }

    /// 執行外部指令，超過 timeout 秒先送 SIGTERM，termGrace 秒後仍在就 SIGKILL。
    /// 輸出（stdout 與 stderr 合併）用 readabilityHandler 持續讀取，輸出很多也不會因為 pipe 滿了而卡住。
    /// 逾時時 code 是子程序被終止後的結束狀態（理論上不會還在跑，萬一還在則為 -1），由呼叫者決定要不要改寫
    static func execute(_ exe: String, _ args: [String], env: [String: String]? = nil,
                        timeout: TimeInterval, termGrace: TimeInterval = 1) async -> Outcome {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                if let env { p.environment = env }
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
                    cont.resume(returning: Outcome(code: 127, output: "", timedOut: false,
                                                   launchError: error.localizedDescription))
                    return
                }
                var timedOut = false
                if exited.wait(timeout: .now() + timeout) == .timedOut {
                    timedOut = true
                    p.terminate()
                    // 寬限期讓子程序的 trap 收尾（例：輔助程式結束 swanctl、清暫存檔）；
                    // SIGKILL 無法經 sudo 轉送給孫程序，只能當最後手段
                    if exited.wait(timeout: .now() + termGrace) == .timedOut {
                        kill(p.processIdentifier, SIGKILL)
                        _ = exited.wait(timeout: .now() + 1)
                    }
                }
                // 等剩下的輸出讀完；孫程序若還握著 pipe，最多再等 1 秒
                if eof.wait(timeout: .now() + 1) == .timedOut {
                    pipe.fileHandleForReading.readabilityHandler = nil
                }
                let out = String(decoding: buf.value, as: UTF8.self)
                let code: Int32 = p.isRunning ? -1 : p.terminationStatus
                cont.resume(returning: Outcome(code: code, output: out, timedOut: timedOut, launchError: nil))
            }
        }
    }

    /// 診斷、主機檢查、一鍵更新用：逾時 1 秒寬限後 SIGKILL，結果包成 DiagnosticReport.CommandResult
    static func runLimited(_ exe: String, _ args: [String], timeout: TimeInterval) async -> DiagnosticReport.CommandResult {
        let r = await execute(exe, args, timeout: timeout)
        if let err = r.launchError {
            return DiagnosticReport.CommandResult(code: 127, output: "無法執行 \(exe)：\(err)", seconds: timeout)
        }
        return DiagnosticReport.CommandResult(code: r.code, output: r.output, timedOut: r.timedOut, seconds: timeout)
    }
}
