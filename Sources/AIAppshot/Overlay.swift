import AppKit

/// CleanShot X風：撮った画像を画面の左下にサムネイルで積んでおく
@MainActor
final class Overlay {
    static let shared = Overlay()

    /// 送るボタンが押されたとき（target が nil なら「自動」）
    var onSend: ((Shot, Target?) -> Void)?
    /// 描くボタンが押されたとき
    var onEdit: ((Shot) -> Void)?

    private var panels: [NSPanel] = []
    private let maxItems = 4
    private let width: CGFloat = 220
    private let margin: CGFloat = 16
    private let spacing: CGFloat = 10

    func add(_ shot: Shot) {
        if panels.count >= maxItems { close(panels[0]) }
        guard let image = NSImage(data: shot.png) else { return }

        let aspect = image.size.height / max(image.size.width, 1)
        let height = min(max(width * aspect, 90), 180)
        let panel = ShotPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = ThumbnailView(frame: NSRect(x: 0, y: 0, width: width, height: height), shot: shot, image: image)
        view.onClose = { [weak self, weak panel] in
            if let panel { self?.close(panel) }
        }
        view.onSend = { [weak self] t in self?.onSend?(shot, t) }
        view.onEdit = { [weak self] in self?.onEdit?(shot) }
        panel.contentView = view

        // 画面左外から滑り込ませる
        panels.append(panel)
        let frames = targetFrames()
        if var start = frames[ObjectIdentifier(panel)] {
            start.origin.x = (screen()?.visibleFrame.minX ?? 0) - width
            panel.setFrame(start, display: false)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        layout(frames)
    }

    func close(_ panel: NSPanel) {
        guard let i = panels.firstIndex(of: panel) else { return }
        panels.remove(at: i)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
        layout(targetFrames())
    }

    func closeAll() {
        for p in panels { close(p) }
    }

    private func screen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    /// 新しいものほど下。上へ積み上げる
    private func targetFrames() -> [ObjectIdentifier: NSRect] {
        guard let vf = screen()?.visibleFrame else { return [:] }
        var result: [ObjectIdentifier: NSRect] = [:]
        var y = vf.minY + margin
        for p in panels.reversed() {
            let size = p.frame.size
            result[ObjectIdentifier(p)] = NSRect(x: vf.minX + margin, y: y, width: size.width, height: size.height)
            y += size.height + spacing
        }
        return result
    }

    private func layout(_ frames: [ObjectIdentifier: NSRect]) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for p in panels {
                if let f = frames[ObjectIdentifier(p)] { p.animator().setFrame(f, display: true) }
                p.animator().alphaValue = 1
            }
        }
    }
}

final class ShotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// マウスが乗ったときだけボタンを出すサムネイル。ドラッグで画像ファイルとして他のアプリへ渡せる
final class ThumbnailView: NSView, NSDraggingSource {
    var onClose: (() -> Void)?
    var onSend: ((Target?) -> Void)?
    var onEdit: (() -> Void)?

    private let shot: Shot
    private let image: NSImage
    private let hover = PassThroughView()
    private var downEvent: NSEvent?

    init(frame: NSRect, shot: Shot, image: NSImage) {
        self.shot = shot
        self.image = image
        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill

        hover.frame = bounds
        hover.autoresizingMask = [.width, .height]
        hover.wantsLayer = true
        hover.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        hover.isHidden = true
        addSubview(hover)

        // 中央：送る / コピー / 保存
        let row = NSStackView(views: [
            button("paperplane.fill", "送る", #selector(sendTapped(_:))),
            button("pencil.tip", "矢印・囲みを描く", #selector(editTapped)),
            button("doc.on.doc", "コピー", #selector(copyTapped)),
            button("square.and.arrow.down", "保存", #selector(saveTapped)),
        ])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        hover.addSubview(row)

        // 右上：閉じる
        let close = button("xmark", "閉じる", #selector(closeTapped), size: 22)
        close.translatesAutoresizingMaskIntoConstraints = false
        hover.addSubview(close)

        // 左下：テキスト文字数
        let label = NSTextField(labelWithString: shot.text.isEmpty ? "画像のみ" : "テキスト \(shot.text.count)字")
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.85)
        label.translatesAutoresizingMaskIntoConstraints = false
        hover.addSubview(label)

        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: hover.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: hover.centerYAnchor),
            close.topAnchor.constraint(equalTo: hover.topAnchor, constant: 6),
            close.trailingAnchor.constraint(equalTo: hover.trailingAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: hover.leadingAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: hover.bottomAnchor, constant: -6),
        ])

        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func button(_ symbol: String, _ tip: String, _ action: Selector, size: CGFloat = 34) -> NSButton {
        let b = FirstMouseButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: size * 0.42, weight: .semibold))
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        b.target = self
        b.action = action
        b.wantsLayer = true
        b.layer?.cornerRadius = size / 2
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: size).isActive = true
        b.heightAnchor.constraint(equalToConstant: size).isActive = true
        return b
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hover.isHidden = false }
    override func mouseExited(with event: NSEvent) { hover.isHidden = true }

    // MARK: - クリック・ドラッグ

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        if event.clickCount == 2 { NSWorkspace.shared.open(shot.fileURL) }  // ダブルクリックでプレビュー
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 4 else { return }
        downEvent = nil
        let item = NSDraggingItem(pasteboardWriter: shot.fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: down, source: self)
    }

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        if !operation.isEmpty { onClose?() }  // どこかに落としたら片付ける
    }

    // MARK: - ボタン

    @objc private func sendTapped(_ sender: NSButton) {
        let menu = NSMenu()
        let auto = NSMenuItem(title: "自動（最後に使ったAI: \(target(for: Settings.lastAI)?.name ?? "-")）",
                              action: #selector(sendChosen(_:)), keyEquivalent: "")
        auto.target = self
        menu.addItem(auto)
        menu.addItem(.separator())
        for t in allTargets {
            let item = NSMenuItem(title: t.name, action: #selector(sendChosen(_:)), keyEquivalent: "")
            item.representedObject = t.bundleID
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func sendChosen(_ sender: NSMenuItem) {
        onSend?(target(for: sender.representedObject as? String))
    }

    @objc private func copyTapped() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(shot.png, forType: .png)
        pb.setData(shot.tiff, forType: .tiff)
        flash()
    }

    @objc private func saveTapped() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let dest = desktop.appendingPathComponent(shot.fileURL.lastPathComponent)
        try? FileManager.default.copyItem(at: shot.fileURL, to: dest)
        flash()
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func editTapped() { onEdit?() }

    private func flash() {
        let a = CABasicAnimation(keyPath: "borderColor")
        a.fromValue = NSColor.systemGreen.cgColor
        a.toValue = layer?.borderColor
        a.duration = 0.6
        layer?.add(a, forKey: "flash")
    }
}

/// 自分自身はクリックを受けず、下のサムネイルに渡す（子のボタンは押せる）
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}

final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
