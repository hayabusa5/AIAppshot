import AppKit
import ApplicationServices
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotkey: HotkeyMonitor!
    private var lastFront: NSRunningApplication?
    private var busy = false
    private var lastStatus = "待機中"
    private var wasTrusted = false
    private var pickedBundleID: String?

    func applicationDidFinishLaunching(_ n: Notification) {
        // 検証用: --dump <bundleID> でそのアプリの抽出テキストを書き出して終了
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--dump"), i + 1 < args.count {
            dumpText(bundleID: args[i + 1])
            NSApp.terminate(nil)
            return
        }
        if args.contains("--selftest") {
            selfTest()
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(busy: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        lastFront = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        hotkey = HotkeyMonitor(
            onCommand: { [weak self] in MainActor.assumeIsolated { self?.trigger(useFrontmost: true) } },
            onOption: { [weak self] in MainActor.assumeIsolated { self?.triggerRegion() } })
        hotkey.start()

        Capture.cleanCache()
        if CommandLine.arguments.contains("--demo") { showDemo() }
        Overlay.shared.onSend = { [weak self] shot, t in
            self?.send(shot, to: t ?? target(for: Settings.lastAI) ?? allTargets[0])
        }
        Overlay.shared.onEdit = { [weak self] shot in
            Annotator.open(shot) { edited in self?.deliver(edited, force: true) }
        }

        // 権限の確認（初回はシステムのダイアログが出る）
        wasTrusted = AXIsProcessTrusted()
        if !wasTrusted {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

        // アクセシビリティが後から許可されたら、ホットキー監視を張り直す
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = AXIsProcessTrusted()
                if now && !self.wasTrusted { self.hotkey.start() }
                self.wasTrusted = now
            }
        }
    }

    @objc private func appActivated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != getpid() else { return }
        if let id = app.bundleIdentifier, target(for: id) != nil { Settings.lastAI = id }
        lastFront = app
    }

    // MARK: - 撮影 → 貼り付け

    private func trigger(useFrontmost: Bool) {
        guard !busy else { return }
        var source = useFrontmost ? NSWorkspace.shared.frontmostApplication : lastFront
        if source?.processIdentifier == getpid() { source = lastFront }
        guard let source else { return }

        busy = true
        setIcon(busy: true)
        Task { @MainActor in
            defer {
                busy = false
                setIcon(busy: false)
            }
            do {
                let shot = try await Capture.shoot(app: source, includeText: Settings.includeText)
                if Settings.playSound { NSSound(named: "Tink")?.play() }
                try await deliverNow(shot, force: false)
            } catch {
                lastStatus = "失敗: \(error.localizedDescription)"
                NSSound.beep()
            }
        }
    }

    /// 範囲を選んで撮る（左右⌥の同時押し、またはメニュー）
    private func triggerRegion() {
        guard !busy else { return }
        var source = NSWorkspace.shared.frontmostApplication
        if source?.processIdentifier == getpid() { source = lastFront }

        busy = true
        setIcon(busy: true)
        Task { @MainActor in
            defer {
                busy = false
                setIcon(busy: false)
            }
            // ⌥を押したまま選ぶと選択の挙動が変わるので、離すまで待つ
            for _ in 0..<40 where !NSEvent.modifierFlags.intersection([.option, .command]).isEmpty {
                try? await Task.sleep(for: .milliseconds(50))
            }
            do {
                guard let shot = try await Capture.shootRegion(
                    appName: source?.localizedName ?? "", includeText: Settings.includeText) else {
                    lastStatus = "範囲撮影をキャンセルしました"
                    return
                }
                if Settings.playSound { NSSound(named: "Tink")?.play() }
                if Settings.annotateRegion {
                    // 描き終えて「送る」を押したら届ける
                    Annotator.open(shot) { [weak self] edited in self?.deliver(edited, force: true) }
                    lastStatus = "範囲を撮影（矢印・囲みを描いて送る）"
                } else {
                    try await deliverNow(shot, force: false)
                }
            } catch {
                lastStatus = "失敗: \(error.localizedDescription)"
                NSSound.beep()
            }
        }
    }

    /// 撮った画像をサムネイルに置き、AIアプリに貼る
    /// force: 「撮影後すぐAIに貼る」がオフでも貼る（エディタの「送る」など）
    private func deliver(_ shot: Shot, force: Bool) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await deliverNow(shot, force: force)
            } catch {
                lastStatus = "失敗: \(error.localizedDescription)"
                NSSound.beep()
            }
        }
    }

    private func deliverNow(_ shot: Shot, force: Bool) async throws {
        if Settings.showThumbnail { Overlay.shared.add(shot) }
        guard Settings.autoPaste || force else {
            lastStatus = "\(shot.appName) を撮影（左下に保持）"
            return
        }
        guard let t = chooseTarget() else {
            lastStatus = "キャンセルしました"
            return
        }
        try await Paster.paste(shot, to: t)
        lastStatus = "\(shot.appName) → \(t.name)（テキスト \(shot.text.count) 文字）"
    }

    private func dumpText(bundleID: String) {
        let out = Capture.cacheDir.appendingPathComponent("dump-\(bundleID).txt")
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            try? "not running".write(to: out, atomically: true, encoding: .utf8)
            return
        }
        Capture.debugFrames = true
        let text = Capture.extractText(pid: app.processIdentifier)
        let frames = Capture.debugLog.joined(separator: "\n")
        let body = "method: \(Capture.lastMethod)\nchars: \(text.count)\ntrusted: \(AXIsProcessTrusted())\n--- frames\n\(frames)\n---\n\(text)"
        try? body.write(to: out, atomically: true, encoding: .utf8)
    }

    /// 検証用: 文字認識と、矢印・四角の焼き込みを試して cacheDir/selftest-* に書き出す
    private func selfTest() {
        let size = NSSize(width: 1600, height: 900)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor.white.setFill(); r.fill()
            ("AIAppshot の自己テスト 123" as NSString).draw(at: NSPoint(x: 120, y: 520), withAttributes: [
                .font: NSFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.black])
            ("Hello, region capture!" as NSString).draw(at: NSPoint(x: 120, y: 360), withAttributes: [
                .font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.darkGray])
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]), let cg = rep.cgImage else { return }
        let ocr = Capture.recognizeText(cg)
        try? "ocr:\n\(ocr)".write(to: Capture.cacheDir.appendingPathComponent("selftest-ocr.txt"), atomically: true, encoding: .utf8)

        let url = Capture.cacheDir.appendingPathComponent("selftest.png")
        try? png.write(to: url)
        let shot = Shot(appName: "Test", windowTitle: "", png: png, tiff: tiff, text: ocr, fileURL: url)
        let px = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        let marks = [
            Mark(tool: .rect, a: CGPoint(x: 100, y: 500), b: CGPoint(x: 1300, y: 620)),
            Mark(tool: .arrow, a: CGPoint(x: 1400, y: 150), b: CGPoint(x: 900, y: 380)),
        ]
        _ = Annotator.burn(shot, image: img, pixelSize: px, marks: marks, lineWidth: max(5, px.width / 170))
    }

    /// 動作確認用：権限なしでサムネイルの見た目だけ出す
    private func showDemo() {
        let colors: [NSColor] = [.systemBlue, .systemOrange, .systemPurple]
        for (i, c) in colors.enumerated() {
            let img = NSImage(size: NSSize(width: 1200, height: 800), flipped: false) { r in
                c.setFill(); r.fill()
                ("Demo \(i + 1)" as NSString).draw(at: NSPoint(x: 80, y: 360), withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 120), .foregroundColor: NSColor.white])
                return true
            }
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let url = Capture.cacheDir.appendingPathComponent("demo-\(i).png")
            try? png.write(to: url)
            let shot = Shot(appName: "Demo", windowTitle: "", png: png, tiff: tiff, text: "", fileURL: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) {
                MainActor.assumeIsolated { Overlay.shared.add(shot) }
            }
        }
        // --expand を付けると、少しあとで広げた状態も確認できる
        if CommandLine.arguments.contains("--expand") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated { Overlay.shared.toggle() }
            }
        }
    }

    /// サムネイルの「送る」から
    private func send(_ shot: Shot, to t: Target) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await Paster.paste(shot, to: t)
                lastStatus = "\(shot.appName) → \(t.name)（サムネイルから）"
            } catch {
                lastStatus = "失敗: \(error.localizedDescription)"
                NSSound.beep()
            }
        }
    }

    private func chooseTarget() -> Target? {
        let mode = Settings.mode
        if mode == "pick" { return pick() }
        if mode.hasPrefix("fixed:") { return target(for: String(mode.dropFirst(6))) }
        return target(for: Settings.lastAI) ?? allTargets[0]
    }

    /// マウス位置にメニューを出して送り先を選ぶ（1〜4キーでも選べる）
    private func pick() -> Target? {
        pickedBundleID = nil
        let menu = NSMenu()
        let title = NSMenuItem(title: "送り先を選ぶ", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for (i, t) in allTargets.enumerated() {
            let item = NSMenuItem(title: "\(i + 1)  \(t.name)", action: #selector(picked(_:)), keyEquivalent: "\(i + 1)")
            item.keyEquivalentModifierMask = []
            item.representedObject = t.bundleID
            item.target = self
            menu.addItem(item)
        }
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return target(for: pickedBundleID)
    }

    @objc private func picked(_ sender: NSMenuItem) {
        pickedBundleID = sender.representedObject as? String
    }

    private func setIcon(busy: Bool) {
        let name = busy ? "camera.viewfinder.fill" : "camera.viewfinder"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AIAppshot")
            ?? NSImage(systemSymbolName: "camera", accessibilityDescription: "AIAppshot")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: - メニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        addLabel(menu, "左右の⌘を同時押し → ウインドウを撮って貼る")
        addLabel(menu, "左右の⌥を同時押し → 範囲を選んで撮る")
        menu.addItem(.separator())

        addLabel(menu, "送り先")
        let lastName = target(for: Settings.lastAI)?.name ?? "-"
        addItem(menu, "自動（最後に使ったAI: \(lastName)）", #selector(setMode(_:)), rep: "auto", on: Settings.mode == "auto")
        addItem(menu, "毎回選ぶ", #selector(setMode(_:)), rep: "pick", on: Settings.mode == "pick")
        for t in allTargets {
            let rep = "fixed:\(t.bundleID)"
            addItem(menu, "\(t.name) に固定", #selector(setMode(_:)), rep: rep, on: Settings.mode == rep)
        }
        menu.addItem(.separator())

        addItem(menu, "範囲を選んで撮る", #selector(regionNow))
        addItem(menu, "範囲撮影のあと矢印・囲みを描く", #selector(toggleAnnotate), on: Settings.annotateRegion)
        addItem(menu, "撮影後すぐAIに貼る", #selector(toggleAutoPaste), on: Settings.autoPaste)
        addItem(menu, "左下にサムネイルを出す", #selector(toggleThumbnail), on: Settings.showThumbnail)
        addItem(menu, "サムネイルをすべて閉じる", #selector(closeThumbnails))
        menu.addItem(.separator())
        addLabel(menu, "テキスト（画面外の文字を含む）の渡し方")
        addItem(menu, "添付ファイルで渡す", #selector(setTextMode(_:)), rep: "file", on: Settings.textMode == "file")
        addItem(menu, "入力欄に貼る", #selector(setTextMode(_:)), rep: "inline", on: Settings.textMode == "inline")
        addItem(menu, "渡さない（画像だけ）", #selector(setTextMode(_:)), rep: "none", on: Settings.textMode == "none")
        menu.addItem(.separator())
        addItem(menu, "効果音を鳴らす", #selector(toggleSound), on: Settings.playSound)
        addItem(menu, "今すぐ撮る（直前のウインドウ）", #selector(shootNow))
        menu.addItem(.separator())

        let ax = AXIsProcessTrusted()
        let sc = CGPreflightScreenCaptureAccess()
        addItem(menu, "アクセシビリティ: " + (ax ? "許可済み" : "未許可（クリックで設定を開く）"),
                ax ? nil : #selector(openAXSettings))
        addItem(menu, "画面収録: " + (sc ? "許可済み" : "未許可（クリックで設定を開く）"),
                sc ? nil : #selector(openScreenSettings))
        addItem(menu, "ログイン時に起動", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        addItem(menu, "再起動", #selector(relaunch))
        menu.addItem(.separator())

        addLabel(menu, "直近: \(lastStatus)")
        addItem(menu, "終了", #selector(quit))
    }

    private func addLabel(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector?, rep: Any? = nil, on: Bool = false) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = rep
        item.state = on ? .on : .off
        if action == nil { item.isEnabled = false }
        menu.addItem(item)
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        if let m = sender.representedObject as? String { Settings.mode = m }
    }
    @objc private func setTextMode(_ sender: NSMenuItem) {
        if let m = sender.representedObject as? String { Settings.textMode = m }
    }
    @objc private func toggleAutoPaste() { Settings.autoPaste.toggle() }
    @objc private func toggleAnnotate() { Settings.annotateRegion.toggle() }
    @objc private func regionNow() {
        // メニューを閉じきってから撮る
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated { self.triggerRegion() }
        }
    }
    @objc private func toggleThumbnail() { Settings.showThumbnail.toggle() }
    @objc private func closeThumbnails() { Overlay.shared.closeAll() }
    @objc private func toggleSound() { Settings.playSound.toggle() }
    @objc private func shootNow() { trigger(useFrontmost: false) }

    @objc private func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openScreenSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastStatus = "ログイン項目の変更に失敗: \(error.localizedDescription)"
        }
    }

    @objc private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundlePath)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
