// 系統全域熱鍵：Carbon RegisterEventHotKey 不需要輔助使用權限，App 不在前景時也收得到。
import Carbon.HIToolbox

@MainActor
final class GlobalHotKey: ObservableObject {
    static let shared = GlobalHotKey()
    var onPress: () -> Void = {}
    /// 錄製新熱鍵時暫停，否則按下目前那組會直接開視窗，錄製畫面收不到。
    var suspended = false { didSet { sync() } }
    /// 想註冊卻失敗（通常是其他 App 已佔用同一組）。
    @Published private(set) var conflict = false

    /// 只在外掛啟用時註冊；關閉外掛時不留任何系統資源。
    func sync() {
        let wanted = PluginRunner.shared.isActive && !suspended ? PluginShortcuts.hotKey() : nil
        let ok = update(wanted)
        if conflict != !ok { conflict = !ok }
    }
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var registered: PluginShortcuts.HotKey?

    /// 傳 nil 取消註冊；同一組按鍵重複呼叫不會重新註冊。回傳是否註冊成功（被其他 App 佔用時失敗）。
    @discardableResult
    func update(_ hotKey: PluginShortcuts.HotKey?) -> Bool {
        if hotKey == registered, (hotKey == nil) == (ref == nil) { return true }
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        registered = nil
        guard let hotKey else { return true }
        installHandler()
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5357_484B), id: 1) // 'SWHK'
        guard RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, id, GetApplicationEventTarget(), 0, &newRef) == noErr,
              let newRef else { return false }
        ref = newRef
        registered = hotKey
        return true
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.onPress() } }
            return noErr
        }, 1, &type, nil, &handler)
    }
}
