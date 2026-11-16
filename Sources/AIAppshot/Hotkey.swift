import AppKit

/// 修飾キーの左右同時押しを検出する
/// - 左右⌘: ウインドウ撮影
/// - 左右⌥: 範囲撮影
final class HotkeyMonitor {
    private let onCommand: () -> Void
    private let onOption: () -> Void
    private var monitors: [Any] = []
    private var firedCmd = false
    private var firedOpt = false

    // デバイス依存の修飾キーフラグ（IOKit NX_DEVICE*KEYMASK）
    private let leftCmd: UInt = 0x08
    private let rightCmd: UInt = 0x10
    private let leftOpt: UInt = 0x20
    private let rightOpt: UInt = 0x40

    init(onCommand: @escaping () -> Void, onOption: @escaping () -> Void) {
        self.onCommand = onCommand
        self.onOption = onOption
    }

    func start() {
        stop()
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            self?.handle(e)
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            self?.handle(e)
            return e
        }) { monitors.append(l) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func handle(_ e: NSEvent) {
        let raw = e.modifierFlags.rawValue
        check(raw & leftCmd != 0, raw & rightCmd != 0, &firedCmd, onCommand)
        check(raw & leftOpt != 0, raw & rightOpt != 0, &firedOpt, onOption)
    }

    private func check(_ left: Bool, _ right: Bool, _ fired: inout Bool, _ action: () -> Void) {
        if left && right {
            if !fired {
                fired = true
                action()
            }
        } else if !left && !right {
            fired = false
        }
    }
}
