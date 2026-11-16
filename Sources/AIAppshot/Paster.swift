import AppKit

enum PasteError: LocalizedError {
    case appNotFound(String), activateFailed(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let n): return "\(n) が見つかりません"
        case .activateFailed(let n): return "\(n) を前面に出せませんでした"
        }
    }
}

/// 送り先アプリを前面に出して、クリップボード経由で貼り付ける（送信はしない）
enum Paster {
    static func paste(_ shot: Shot, to target: Target) async throws {
        try await activate(target)

        let pb = NSPasteboard.general
        let saved = snapshot(pb)

        // 1. 画像
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(shot.png, forType: .png)
        pb.setData(shot.tiff, forType: .tiff)
        sendCommandV()

        // 2. テキスト（入力欄には書かず、添付ファイルとして渡すのが標準）
        let mode = Settings.textMode
        if !shot.text.isEmpty && mode != "none" {
            try await Task.sleep(for: .milliseconds(700))
            var header = "[Appshot] \(shot.appName)"
            if !shot.windowTitle.isEmpty { header += " — \(shot.windowTitle)" }
            let body = "\(header)\n---\n\(shot.text)"
            pb.clearContents()
            if mode == "inline" {
                pb.setString(body, forType: .string)
            } else {
                let url = try writeTextFile(body, shot: shot)
                pb.writeObjects([url as NSURL])
            }
            sendCommandV()
        }

        // 3. 元のクリップボードに戻す
        try await Task.sleep(for: .milliseconds(1200))
        restore(pb, saved)
    }

    /// 画像と同じ名前の .txt を書き出す
    private static func writeTextFile(_ body: String, shot: Shot) throws -> URL {
        let url = shot.fileURL.deletingPathExtension().appendingPathExtension("txt")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func activate(_ target: Target) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) else {
            throw PasteError.appNotFound(target.name)
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)

        // 前面に来るまで最大5秒待つ
        for _ in 0..<50 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleID {
                try await Task.sleep(for: .milliseconds(350))  // 入力欄にフォーカスが当たるのを待つ
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PasteError.activateFailed(target.name)
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { dict[t] = d } }
            return dict
        }
    }

    private static func restore(_ pb: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
