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

    /// 只讀不寫：系統快捷鍵（plist 與 CopySymbolicHotKeys）、「服務」快捷鍵。只在錄製與開啟設定視窗時呼叫。
    static func conflictSources() -> HotKeyConflicts.Sources {
        let symbolic = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
        let services = CFPreferencesCopyAppValue("NSServicesStatus" as CFString, "pbs" as CFString)
        var copied: Unmanaged<CFArray>?
        let effective = CopySymbolicHotKeys(&copied) == noErr
            ? (copied?.takeRetainedValue() as? [[String: Any]]).map(HotKeyConflicts.parseEffective) : nil
        return HotKeyConflicts.Sources(symbolic: HotKeyConflicts.parseSymbolic(symbolic), effective: effective,
                                       services: HotKeyConflicts.parseServices(services, layout: keyLayout()))
    }

    /// 目前鍵盤配置下每個鍵（不按與按住 Shift）打出的字元。注音等輸入法沒有 uchr，改用它對應的英數配置。
    static func keyLayout() -> HotKeyConflicts.KeyLayout {
        func layoutData(_ source: TISInputSource?) -> CFData? {
            guard let source, let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        }
        let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let data = layoutData(current) ?? layoutData(ascii) else { return [:] }
        var layout: HotKeyConflicts.KeyLayout = [:]
        let bytes = CFDataGetBytePtr(data)!
        bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { keyboard in
            func translate(_ keyCode: UInt16, shift: Bool) -> String? {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let state = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                guard UCKeyTranslate(keyboard, keyCode, UInt16(kUCKeyActionDown), state, UInt32(LMGetKbdType()),
                                     OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars) == noErr,
                      length == 1 else { return nil }
                return String(utf16CodeUnits: chars, count: length)
            }
            for keyCode in UInt16(0)..<128 {
                let plain = translate(keyCode, shift: false)
                let shifted = translate(keyCode, shift: true)
                if let plain { layout[plain, default: []].append(.init(keyCode: UInt32(keyCode), shift: false)) }
                // 數字鍵盤等按不按 Shift 都打出同一字元的鍵，只算不按 Shift
                if let shifted, shifted != plain { layout[shifted, default: []].append(.init(keyCode: UInt32(keyCode), shift: true)) }
            }
        }
        return layout
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
