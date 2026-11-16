import AppKit
import ApplicationServices

/// Accessibility API でウインドウの「本文」だけを取り出す（画面外にスクロールした部分も含む）
///
/// 1. Webベースのアプリ（Electron等）で <main> にあたる領域があれば、そこだけを対象にする
///    さらに TextMarker API で、画面に描かれたままの改行付きテキストを取る
/// 2. 無ければウインドウ全体をたどり、サイドバー・ツールバー・ナビゲーションを飛ばす
extension Capture {
    /// 最後にどの方法で取ったか（検証用）
    nonisolated(unsafe) static var lastMethod = ""
    nonisolated(unsafe) static var debugFrames = false
    nonisolated(unsafe) static var debugLog: [String] = []

    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading"]
    private static let skipRoles: Set<String> = ["AXToolbar", "AXMenuBar", "AXMenu", "AXScrollBar"]
    private static let skipSubroles: Set<String> = [
        "AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkContentInfo",
        "AXLandmarkComplementary", "AXSourceList",
    ]

    static func extractText(pid: pid_t, maxChars: Int = 40_000) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        // Electron系アプリはこれでアクセシビリティツリーを公開する
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let w = attr(app, kAXFocusedWindowAttribute) ?? attr(app, kAXMainWindowAttribute)
            ?? (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first else {
            lastMethod = "no-window"
            return ""
        }
        let window = w as! AXUIElement
        let deadline = Date().addingTimeInterval(2.5)
        let winFrame = frame(of: window)

        // 1. <main> 領域
        let mains = findMains(in: window, deadline: deadline)
        if !mains.isEmpty {
            let walked = walk(roots: mains, winFrame: winFrame, deadline: deadline, maxChars: maxChars)
            if !walked.isEmpty {
                lastMethod = "main+walk"
                return finish(walked, maxChars)
            }
            let texts = mains.compactMap { markerText($0) }.filter { !$0.isEmpty }
            if !texts.isEmpty {
                lastMethod = "main+marker"
                return finish(texts.joined(separator: "\n\n"), maxChars)
            }
        }

        // 2. ウインドウ全体（サイドバー等を除く）
        lastMethod = "window+walk"
        return finish(walk(roots: [window], winFrame: winFrame, deadline: deadline, maxChars: maxChars), maxChars)
    }

    private static func finish(_ raw: String, _ maxChars: Int) -> String {
        // 空行の連続を詰める
        var lines: [String] = []
        let cleaned = raw.replacingOccurrences(of: "\u{FFFC}", with: "")  // 埋め込みオブジェクトの記号
        for l in cleaned.components(separatedBy: .newlines) {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(t)
        }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxChars { text = String(text.prefix(maxChars)) + "\n…（以下省略）" }
        return text
    }

    /// subrole が AXLandmarkMain の要素を探す（見つけたらその中には潜らない）
    private static func findMains(in root: AXUIElement, deadline: Date) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 6_000, Date() < deadline {
            let (el, depth) = queue.removeFirst()
            visited += 1
            if (attr(el, kAXSubroleAttribute) as? String) == "AXLandmarkMain" {
                result.append(el)
                continue
            }
            if depth < 40, let children = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return result
    }

    /// Chromium / WebKit の TextMarker API で、要素内のテキストを改行付きで丸ごと取る
    private static func markerText(_ el: AXUIElement) -> String? {
        var range: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, "AXTextMarkerRangeForUIElement" as CFString, el, &range) == .success, let range else { return nil }
        var str: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, "AXStringForTextMarkerRange" as CFString, range, &str) == .success else { return nil }
        return str as? String
    }

    /// テキスト要素を順にたどり、画面上の位置で改行を復元する
    /// （同じ行に並ぶ断片はつなげ、下の段に移ったら改行する）
    private static func walk(roots: [AXUIElement], winFrame: CGRect?, deadline: Date, maxChars: Int) -> String {
        var out = ""
        var prevFrame: CGRect?
        var seen = Set<String>()
        var total = 0
        var visited = 0

        func append(_ s: String, frame f: CGRect?) {
            if debugFrames, debugLog.count < 60 { debugLog.append("\(f.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "nil") | \(s.prefix(30))") }
            // 右に続いていれば同じ行。画面外の要素は縦位置が潰れる（高さ1）ので、縦は見える時だけ比べる
            let sameLine: Bool = {
                guard let f, let p = prevFrame else { return false }
                guard f.minX >= p.maxX - 3 else { return false }
                if f.height > 2 && p.height > 2 { return f.minY < p.maxY - 2 }
                return true
            }()
            if sameLine {
                out += s  // 前の断片と同じ行（コードのハイライトやリンクの分割）
            } else {
                if !out.isEmpty { out += "\n" }
                out += s
            }
            prevFrame = f
        }

        func isSidebar(_ el: AXUIElement) -> Bool {
            guard let win = winFrame, let f = frame(of: el) else { return false }
            let narrow = f.width < win.width * 0.3
            let tall = f.height > win.height * 0.5
            let atEdge = abs(f.minX - win.minX) < 24 || abs(win.maxX - f.maxX) < 24
            return narrow && tall && atEdge
        }

        func visit(_ el: AXUIElement, depth: Int) {
            if depth > 80 || visited > 10_000 || total > maxChars || Date() > deadline { return }
            visited += 1
            let role = attr(el, kAXRoleAttribute) as? String ?? ""
            let subrole = attr(el, kAXSubroleAttribute) as? String ?? ""
            if skipRoles.contains(role) || skipSubroles.contains(subrole) { return }
            if depth > 0, !textRoles.contains(role), isSidebar(el) { return }

            if textRoles.contains(role), let v = attr(el, kAXValueAttribute) as? String {
                let s = v.trimmingCharacters(in: .newlines)
                // 長い文の重複（読み上げ用ラベルと本文の二重など）だけ省く。短い記号は残す
                let dup = s.count >= 20 && seen.contains(s)
                if !s.trimmingCharacters(in: .whitespaces).isEmpty, !dup {
                    if s.count >= 20 { seen.insert(s) }
                    append(s, frame: frame(of: el))
                    total += s.count
                }
                if role == "AXTextArea" { return }  // 中身は取得済み
            }
            if let children = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
                for c in children { visit(c, depth: depth + 1) }
            }
        }
        for r in roots { visit(r, depth: 0) }
        return out
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }
}
