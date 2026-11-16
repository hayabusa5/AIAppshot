import AppKit
import ScreenCaptureKit
import ApplicationServices
import Vision

struct Shot {
    let appName: String
    let windowTitle: String
    let png: Data
    let tiff: Data
    let text: String
    let fileURL: URL  // ドラッグ・保存用に書き出したPNG
}

enum CaptureError: LocalizedError {
    case noWindow, captureFailed

    var errorDescription: String? {
        switch self {
        case .noWindow: return "撮影できるウインドウがありません"
        case .captureFailed: return "撮影に失敗しました（画面収録の権限を確認）"
        }
    }
}

enum Capture {
    /// 指定アプリの最前面ウインドウを撮影し、テキストも集める
    static func shoot(app: NSRunningApplication, includeText: Bool) async throws -> Shot {
        let pid = app.processIdentifier
        guard let (windowID, title) = frontWindow(pid: pid) else { throw CaptureError.noWindow }

        // テキスト抽出は撮影と並行して別スレッドで行う
        let textTask = Task.detached { includeText ? extractText(pid: pid) : "" }

        let image = try await captureWindow(windowID)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]),
              let tiff = rep.tiffRepresentation else { throw CaptureError.captureFailed }

        let fileURL = cacheDir.appendingPathComponent("AIAppshot \(timestamp()).png")
        try png.write(to: fileURL)

        return Shot(
            appName: app.localizedName ?? "",
            windowTitle: title,
            png: png,
            tiff: tiff,
            text: await textTask.value,
            fileURL: fileURL
        )
    }

    /// 範囲を選んで撮る（macOS標準の選択UIを使う）。Escでキャンセルされたら nil
    /// テキストは画像から文字認識（OCR）で取る
    static func shootRegion(appName: String, includeText: Bool) async throws -> Shot? {
        let url = cacheDir.appendingPathComponent("AIAppshot \(timestamp()) 範囲.png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", url.path]  // -i: 範囲選択（スペースでウインドウ選択に切替）
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { _ in c.resume() }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
        guard let png = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: png),
              let cg = rep.cgImage,
              let tiff = rep.tiffRepresentation else { return nil }

        let text = includeText ? await Task.detached { recognizeText(cg) }.value : ""
        return Shot(appName: appName, windowTitle: "選択範囲", png: png, tiff: tiff, text: text, fileURL: url)
    }

    /// Vision の文字認識（日本語・英語）
    static func recognizeText(_ image: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["ja-JP", "en-US"]
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIAppshot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 1日以上前の一時ファイルを消す
    static func cleanCache() {
        let fm = FileManager.default
        let old = Date().addingTimeInterval(-86_400)
        for url in (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let d = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate, d < old {
                try? fm.removeItem(at: url)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    /// 前面から順に並んだウインドウ一覧から、そのアプリの通常ウインドウを1つ選ぶ
    private static func frontWindow(pid: pid_t) -> (CGWindowID, String)? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            if let b = w[kCGWindowBounds as String] as? [String: CGFloat],
               (b["Width"] ?? 0) < 80 || (b["Height"] ?? 0) < 80 { continue }
            return (id, w[kCGWindowName as String] as? String ?? "")
        }
        return nil
    }

    private static func captureWindow(_ id: CGWindowID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let win = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        cfg.width = Int(filter.contentRect.width * scale)
        cfg.height = Int(filter.contentRect.height * scale)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

}
