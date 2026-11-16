import AppKit

/// 撮った画像に矢印・四角を描いてからAIに送るエディタ
/// Enter: 送る / Esc: 閉じる / ⌘Z: 戻す / A: 矢印 / R: 四角
@MainActor
final class Annotator: NSObject, NSWindowDelegate {
    private static var current: Annotator?

    private let shot: Shot
    private let onSend: (Shot) -> Void
    private var window: NSWindow!
    private var canvas: CanvasView!
    private var toolControl: NSSegmentedControl!

    static func open(_ shot: Shot, onSend: @escaping (Shot) -> Void) {
        current?.window.close()
        guard let a = Annotator(shot: shot, onSend: onSend) else { return }
        current = a
        a.show()
    }

    private init?(shot: Shot, onSend: @escaping (Shot) -> Void) {
        guard let image = NSImage(data: shot.png), let rep = NSBitmapImageRep(data: shot.png) else { return nil }
        self.shot = shot
        self.onSend = onSend
        super.init()
        canvas = CanvasView(image: image, pixelSize: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh))
    }

    private func show() {
        // 画像を画面に収まる大きさで表示する
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let pt = CGSize(width: canvas.pixelSize.width / backing, height: canvas.pixelSize.height / backing)
        let maxW = min(1200, screen.width * 0.8), maxH = min(800, screen.height * 0.75)
        let scale = min(maxW / pt.width, maxH / pt.height, 1)
        let canvasSize = CGSize(width: max(pt.width * scale, 200), height: max(pt.height * scale, 120))
        let barH: CGFloat = 48
        let width = max(canvasSize.width, 460)

        window = KeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: canvasSize.height + barH),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "矢印・囲みを描く（Enterで送る / Escで閉じる）"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: canvasSize.height + barH))
        canvas.frame = NSRect(x: (width - canvasSize.width) / 2, y: 0, width: canvasSize.width, height: canvasSize.height)
        canvas.onEscape = { [weak self] in self?.window.close() }
        content.addSubview(canvas)

        toolControl = NSSegmentedControl(labels: ["矢印 (A)", "四角 (R)"], trackingMode: .selectOne,
                                         target: self, action: #selector(toolChanged))
        toolControl.selectedSegment = 0
        canvas.onToolKey = { [weak self] t in
            self?.toolControl.selectedSegment = t == .arrow ? 0 : 1
            self?.canvas.tool = t
        }

        let undo = NSButton(title: "戻す", target: self, action: #selector(undoTapped))
        undo.keyEquivalent = "z"
        undo.keyEquivalentModifierMask = .command
        let copy = NSButton(title: "コピー", target: self, action: #selector(copyTapped))
        let send = NSButton(title: "送る", target: self, action: #selector(sendTapped))
        send.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [toolControl, undo, spacer, copy, send])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        bar.frame = NSRect(x: 0, y: canvasSize.height, width: width, height: barH)
        bar.autoresizingMask = [.width]
        content.addSubview(bar)

        window.contentView = content
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    func windowWillClose(_ notification: Notification) {
        if Annotator.current === self { Annotator.current = nil }
    }

    @objc private func toolChanged() {
        canvas.tool = toolControl.selectedSegment == 0 ? .arrow : .rect
        window.makeFirstResponder(canvas)
    }

    @objc private func undoTapped() { canvas.undo() }

    @objc private func copyTapped() {
        guard let s = render() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(s.png, forType: .png)
        pb.setData(s.tiff, forType: .tiff)
        window.title = "コピーしました"
    }

    @objc private func sendTapped() {
        guard let s = render() else { return }
        window.close()
        onSend(s)
    }

    /// 描いた図形を画像に焼き込む（何も描いていなければ元のまま）
    private func render() -> Shot? {
        if canvas.marks.isEmpty { return shot }
        return Annotator.burn(shot, image: canvas.image, pixelSize: canvas.pixelSize,
                              marks: canvas.marks, lineWidth: canvas.lineWidth)
    }

    static func burn(_ shot: Shot, image: NSImage, pixelSize size: CGSize, marks: [Mark], lineWidth: CGFloat) -> Shot? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        for m in marks { CanvasView.draw(m, scale: 1, lineWidth: lineWidth) }
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]), let tiff = rep.tiffRepresentation else { return nil }
        let base = shot.fileURL.deletingPathExtension()
        let url = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + " 注釈.png")
        try? png.write(to: url)
        return Shot(appName: shot.appName, windowTitle: shot.windowTitle, png: png, tiff: tiff, text: shot.text, fileURL: url)
    }
}

/// 編集ウインドウ（常駐アプリでもキー入力を受けられるように）
final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

enum MarkTool { case arrow, rect }

/// 図形（座標は画像のピクセル、原点は左下）
struct Mark {
    var tool: MarkTool
    var a: CGPoint
    var b: CGPoint
}

final class CanvasView: NSView {
    let image: NSImage
    let pixelSize: CGSize
    var tool: MarkTool = .arrow
    private(set) var marks: [Mark] = []
    private var drafting: Mark?
    var onEscape: (() -> Void)?
    var onToolKey: ((MarkTool) -> Void)?

    /// 線の太さ（画像ピクセル）。大きい画像ほど太くする
    var lineWidth: CGFloat { max(5, pixelSize.width / 170) }

    init(image: NSImage, pixelSize: CGSize) {
        self.image = image
        self.pixelSize = pixelSize
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var scale: CGFloat { bounds.width / pixelSize.width }

    private func imagePoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        let x = min(max(p.x, 0), bounds.width), y = min(max(p.y, 0), bounds.height)
        return CGPoint(x: x / scale, y: y / scale)
    }

    override func mouseDown(with e: NSEvent) {
        let p = imagePoint(e)
        drafting = Mark(tool: tool, a: p, b: p)
    }

    override func mouseDragged(with e: NSEvent) {
        drafting?.b = imagePoint(e)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if let d = drafting, hypot(d.a.x - d.b.x, d.a.y - d.b.y) > lineWidth * 2 { marks.append(d) }
        drafting = nil
        needsDisplay = true
    }

    func undo() {
        if !marks.isEmpty { marks.removeLast() }
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: onEscape?()                       // Esc
        case 0: onToolKey?(.arrow)                 // A
        case 15: onToolKey?(.rect)                 // R
        default: super.keyDown(with: e)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        let s = scale
        for m in marks + [drafting].compactMap({ $0 }) {
            CanvasView.draw(m, scale: s, lineWidth: lineWidth * s)
        }
    }

    /// 図形を描く（scale: 画像ピクセル → 描画先の倍率）
    static func draw(_ m: Mark, scale s: CGFloat, lineWidth lw: CGFloat) {
        let a = CGPoint(x: m.a.x * s, y: m.a.y * s)
        let b = CGPoint(x: m.b.x * s, y: m.b.y * s)
        NSColor.systemRed.set()

        switch m.tool {
        case .rect:
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            let path = NSBezierPath(roundedRect: r, xRadius: lw * 1.5, yRadius: lw * 1.5)
            path.lineWidth = lw
            path.stroke()

        case .arrow:
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = lw * 5
            let spread: CGFloat = .pi / 6.5
            // 軸は矢じりの手前まで
            let shaftEnd = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
            let shaft = NSBezierPath()
            shaft.move(to: a)
            shaft.line(to: shaftEnd)
            shaft.lineWidth = lw
            shaft.lineCapStyle = .round
            shaft.stroke()

            let tip = NSBezierPath()
            tip.move(to: b)
            tip.line(to: CGPoint(x: b.x - cos(angle - spread) * head, y: b.y - sin(angle - spread) * head))
            tip.line(to: CGPoint(x: b.x - cos(angle + spread) * head, y: b.y - sin(angle + spread) * head))
            tip.close()
            tip.fill()
        }
    }
}
