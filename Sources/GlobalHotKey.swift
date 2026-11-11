// 系統全域熱鍵：Carbon RegisterEventHotKey 不需要輔助使用權限，App 不在前景時也收得到。
// 每支有設定視窗的外掛各自註冊一組，按下就開啟那支外掛的設定視窗。
import Carbon.HIToolbox

@MainActor
final class GlobalHotKey: ObservableObject {
    static let shared = GlobalHotKey()
    var onPress: (String) -> Void = { _ in }
    /// 錄製新熱鍵時暫停，否則按下已註冊的組合會直接開視窗，錄製畫面收不到。
    var suspended = false { didSet { sync() } }
    /// 想註冊卻被系統拒絕的外掛。其他 App 用同一組不會失敗，按下時兩邊都會收到。
    @Published private(set) var conflicts: Set<String> = []

    private struct Registration { let ref: EventHotKeyRef; let hotKey: PluginShortcuts.HotKey; let number: UInt32 }
    private var registrations: [String: Registration] = [:]
    private var pluginForNumber: [UInt32: String] = [:]
    private var nextNumber: UInt32 = 1
    private var handler: EventHandlerRef?

    /// 有設定視窗且沒有載入問題的外掛。
    static func candidates(_ plugins: [PluginRunner.Plugin]) -> [PluginRunner.Plugin] {
        plugins.filter { p in
            p.problem == nil && (p.package.map { $0.record.manifest.settings } ?? (p.output?.settingsAvailable == true))
        }
    }

    /// 只在外掛啟用時註冊，且只註冊目前還在的外掛；關閉外掛時不留任何系統資源。
    func sync() {
        let runner = PluginRunner.shared
        let ids = Self.candidates(runner.plugins).map(\.id)
        PluginShortcuts.migrateLegacy(candidates: ids)
        let wanted = runner.isActive && !suspended ? PluginShortcuts.hotKeys().filter { ids.contains($0.key) } : [:]
        update(wanted)
    }

    func update(_ wanted: [String: PluginShortcuts.HotKey]) {
        for (id, reg) in registrations where wanted[id] != reg.hotKey {
            UnregisterEventHotKey(reg.ref)
            pluginForNumber[reg.number] = nil
            registrations[id] = nil
        }
        var failed: Set<String> = []
        for (id, hotKey) in wanted.sorted(by: { $0.key < $1.key }) where registrations[id] == nil {
            installHandler()
            let number = nextNumber
            nextNumber &+= 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x5357_484B), id: number) // 'SWHK'
            guard RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
                  let ref else { failed.insert(id); continue }
            registrations[id] = Registration(ref: ref, hotKey: hotKey, number: number)
            pluginForNumber[number] = id
        }
        if conflicts != failed { conflicts = failed }
    }

    private func pressed(_ number: UInt32) {
        if let id = pluginForNumber[number] { onPress(id) }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID) == noErr else { return noErr }
            let number = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.pressed(number) } }
            return noErr
        }, 1, &type, nil, &handler)
    }
}
