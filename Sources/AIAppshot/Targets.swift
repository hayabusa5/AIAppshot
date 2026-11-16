import AppKit

/// 送り先にできるAIアプリ
struct Target {
    let name: String
    let bundleID: String
}

let allTargets: [Target] = [
    Target(name: "Claude", bundleID: "com.anthropic.claudefordesktop"),
    Target(name: "Muse", bundleID: "com.meta.endo"),
    Target(name: "Codex", bundleID: "com.openai.codex"),
    Target(name: "Grok Bot", bundleID: "com.anysphere.sand"),
]

func target(for bundleID: String?) -> Target? {
    allTargets.first { $0.bundleID == bundleID }
}

/// 設定（UserDefaultsに保存）
enum Settings {
    private static let d = UserDefaults.standard

    /// "auto" / "pick" / "fixed:<bundleID>"
    static var mode: String {
        get { d.string(forKey: "mode") ?? "auto" }
        set { d.set(newValue, forKey: "mode") }
    }
    /// 自動モードで使う「最後に使ったAIアプリ」
    static var lastAI: String {
        get { d.string(forKey: "lastAI") ?? allTargets[0].bundleID }
        set { d.set(newValue, forKey: "lastAI") }
    }
    /// テキストの渡し方: "file"（添付ファイル）/ "inline"（入力欄に貼る）/ "none"（渡さない）
    static var textMode: String {
        get { d.string(forKey: "textMode") ?? "file" }
        set { d.set(newValue, forKey: "textMode") }
    }
    static var includeText: Bool { textMode != "none" }
    /// 撮影後すぐAIアプリに貼る
    static var autoPaste: Bool {
        get { d.object(forKey: "autoPaste") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoPaste") }
    }
    /// 左下にサムネイルを出す
    static var showThumbnail: Bool {
        get { d.object(forKey: "showThumbnail") as? Bool ?? true }
        set { d.set(newValue, forKey: "showThumbnail") }
    }
    /// 範囲撮影のあと注釈エディタを開く
    static var annotateRegion: Bool {
        get { d.object(forKey: "annotateRegion") as? Bool ?? true }
        set { d.set(newValue, forKey: "annotateRegion") }
    }
    static var playSound: Bool {
        get { d.bool(forKey: "playSound") }
        set { d.set(newValue, forKey: "playSound") }
    }
}
