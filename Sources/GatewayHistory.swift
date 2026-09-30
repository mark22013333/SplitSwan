// F4 依連線紀錄選閘道（docs/SPEC-1.3.md §6）：記錄每次逐台 `up N` 的結果，
// 自動輪替依過去的實際連線結果排序。純資料與純邏輯，不碰系統狀態，方便單獨測試；
// 存在 UserDefaults 的 JSON 也給 F3 診斷報告讀取。
import Foundation

/// 一次 `up N` 嘗試的結果
struct GatewayAttempt: Codable, Equatable {
    var gateway: Int        // 閘道編號，1 起算（VPN1 = 1）
    var address: String     // 當時的閘道位址；位址改了，舊紀錄就沒有參考價值
    var success: Bool
    var seconds: Double?    // 耗時；不知道時為 nil（舊版遷移的種子、連上後被踢／卡在連線中），不算進平均耗時
    var time: Date
}

struct GatewayHistory: Codable, Equatable {
    static let defaultsKey = "GatewayHistory"
    /// 每台只保留最近幾筆
    static let keepPerGateway = 10
    /// 失敗後多久內算「冷卻中」
    static let cooldown: TimeInterval = 600

    /// 依時間先後排列（新的在後）
    private(set) var attempts: [GatewayAttempt] = []

    // MARK: 讀寫

    mutating func record(_ a: GatewayAttempt) {
        attempts.append(a)
        let mine = attempts.filter { $0.gateway == a.gateway }
        if mine.count > Self.keepPerGateway {
            // 同一台超過上限：從最舊的開始丟
            var drop = mine.count - Self.keepPerGateway
            attempts.removeAll { x in
                guard drop > 0, x.gateway == a.gateway else { return false }
                drop -= 1
                return true
            }
        }
    }

    /// 清除某一台的紀錄
    mutating func clear(gateway n: Int) { attempts.removeAll { $0.gateway == n } }

    /// 清除全部紀錄（設定頁「清除閘道連線紀錄」）
    mutating func removeAll() { attempts.removeAll() }

    /// 1.3 以前只存「上次成功的閘道」（LastGoodGateway，0 起算）。紀錄還是空的時候，
    /// 用它補一筆耗時不明的成功當種子，升級後規則 b 仍然有效
    static func migrated(_ h: GatewayHistory, legacyLastGood: Int?, gateways: [String], now: Date) -> GatewayHistory {
        guard h.attempts.isEmpty, let i = legacyLastGood, gateways.indices.contains(i) else { return h }
        let addr = gateways[i].trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty else { return h }
        var m = h
        m.record(GatewayAttempt(gateway: i + 1, address: addr, success: true, seconds: nil, time: now))
        return m
    }

    /// 移除「位址跟目前設定不同」的紀錄（位址被修改、或閘道被清空）。gateways 為 0 起算的設定清單
    func pruned(gateways: [String]) -> GatewayHistory {
        var h = self
        h.attempts.removeAll { a in
            let i = a.gateway - 1
            guard gateways.indices.contains(i) else { return true }
            return gateways[i].trimmingCharacters(in: .whitespaces).lowercased()
                != a.address.trimmingCharacters(in: .whitespaces).lowercased()
        }
        return h
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(_ data: Data?) -> GatewayHistory {
        guard let data, let h = try? JSONDecoder().decode(GatewayHistory.self, from: data) else { return GatewayHistory() }
        return h
    }

    // MARK: 查詢

    func records(_ n: Int) -> [GatewayAttempt] { attempts.filter { $0.gateway == n } }

    /// 上次成功連上的閘道（所有紀錄中最新的一筆成功）
    var lastSuccess: Int? { attempts.last(where: \.success)?.gateway }

    func isCooling(_ n: Int, now: Date) -> Bool {
        records(n).contains { !$0.success && now.timeIntervalSince($0.time) < Self.cooldown }
    }

    func successRate(_ n: Int) -> Double? {
        let r = records(n)
        guard !r.isEmpty else { return nil }
        return Double(r.filter(\.success).count) / Double(r.count)
    }

    /// 平均耗時，只算成功且知道耗時的那幾筆；沒有這種紀錄回傳 nil
    func averageSuccessSeconds(_ n: Int) -> Double? {
        let secs = records(n).filter(\.success).compactMap(\.seconds)
        guard !secs.isEmpty else { return nil }
        return secs.reduce(0, +) / Double(secs.count)
    }

    /// 從最新一筆往回數的連續失敗次數
    func consecutiveFailures(_ n: Int) -> Int {
        var c = 0
        for a in records(n).reversed() { if a.success { break }; c += 1 }
        return c
    }

    // MARK: 要不要記錄

    /// status 的連線名稱（例：vpn2）→ 閘道編號 2；認不出來回傳 nil
    static func gateway(fromConnection c: String?) -> Int? {
        guard let c = c?.lowercased(), c.hasPrefix("vpn"), let n = Int(c.dropFirst(3)), (1...3).contains(n) else { return nil }
        return n
    }

    /// 一次 up N 的結果要不要記錄。成功一律記；失敗只在「原因確定在閘道」時才記：
    ///   - interrupted（執行中按了斷線、或網路中途斷掉）→ 不記
    ///   - 輸出沒有 helper 的「fail vpnN」→ 不記（例：sudo -n 失敗、輔助程式沒裝好，不是閘道的問題）
    /// 已知限制：charon 起不來時 helper 一樣印 fail vpnN，這裡分辨不出來，會記成該台失敗
    static func shouldRecord(gateway n: Int, success: Bool, output: String, interrupted: Bool) -> Bool {
        if success { return true }
        if interrupted { return false }
        return output.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "fail vpn\(n)" }
    }

    // MARK: 排序

    /// 自動輪替的嘗試順序（回傳 1 起算的閘道編號），前面的規則優先：
    ///   a. 冷卻中（10 分鐘內失敗過）的排到最後，仍會嘗試；冷卻中的彼此之間照 c、d 排
    ///   b. 上次成功連上的閘道排第一（不在冷卻中才算）
    ///   c. 其餘依最近 10 次的成功率由高到低，同分時成功那幾筆的平均耗時短的在前
    ///   d. 沒有紀錄的排在有紀錄的後面，照設定順序；但成功率為 0（有紀錄、全部失敗）的
    ///      排在沒有紀錄的後面（§6.3「連續失敗會排到最後」優先）
    ///   e. 未設定（空白）的閘道略過
    static func order(gateways: [String], history: GatewayHistory, now: Date) -> [Int] {
        let configured = gateways.indices
            .filter { !gateways[$0].trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0 + 1 }
        let last = history.lastSuccess
        // c、d：成功率高 → 平均耗時短（沒成功過視為最慢）→ 設定順序
        func byRecord(_ x: Int, _ y: Int) -> Bool {
            let rx = history.successRate(x), ry = history.successRate(y)
            switch (rx, ry) {
            case (nil, nil): return x < y
            case (nil, _): return false
            case (_, nil): return true
            case let (a?, b?):
                if a != b { return a > b }
                let tx = history.averageSuccessSeconds(x) ?? .infinity
                let ty = history.averageSuccessSeconds(y) ?? .infinity
                if tx != ty { return tx < ty }
                return x < y
            }
        }
        let cooling = configured.filter { history.isCooling($0, now: now) }
        let normal = configured.filter { !cooling.contains($0) }
        let first = normal.filter { $0 == last }
        let rest = normal.filter { $0 != last }
        let succeeded = rest.filter { (history.successRate($0) ?? 0) > 0 }.sorted(by: byRecord)
        let unknown = rest.filter { history.successRate($0) == nil }
        let allFailed = rest.filter { history.successRate($0) == 0 }.sorted(by: byRecord)
        return first + succeeded + unknown + allFailed + cooling.sorted(by: byRecord)
    }

    // MARK: 顯示文字

    /// 最近狀態，例：「上次 3.2 秒連上」、「最近 3 次失敗」；沒有紀錄回傳 nil
    func detail(_ n: Int) -> String? {
        guard let latest = records(n).last else { return nil }
        if latest.success {
            guard let secs = latest.seconds else { return "上次連上" }
            return "上次 \(String(format: "%.1f", secs)) 秒連上"
        }
        return "最近 \(consecutiveFailures(n)) 次失敗"
    }

    /// 例：「VPN2 · 上次 3.2 秒連上」、「VPN1 · 最近 3 次失敗」；沒有紀錄時只有「VPN1」
    func statusText(_ n: Int) -> String {
        detail(n).map { "VPN\(n) · \($0)" } ?? "VPN\(n)"
    }
}
