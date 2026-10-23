import AppKit
import ShiftDropCore

/// Pointer geometry is shared by drawing, hit testing and accessibility.
/// Every offered operation has a reachable sector; the center never performs one.
struct RadialWheelLayout {
    static let diameter: CGFloat = 480
    struct Sector {
        let index: Int
        let inner: CGFloat
        let outer: CGFloat
        let angle: Double
        let span: Double
        var center: CGPoint {
            let r = (inner + outer) / 2
            return CGPoint(x: 240 + sin(angle) * r, y: 240 - cos(angle) * r)
        }
        func contains(_ point: CGPoint) -> Bool {
            let dx = point.x - 240, dy = point.y - 240
            let radius = hypot(dx, dy)
            guard radius >= inner, radius <= outer else { return false }
            let delta = atan2(sin(atan2(dx, -dy) - angle), cos(atan2(dx, -dy) - angle))
            return abs(delta) <= span / 2 - 0.015
        }
    }
    let sectors: [Sector]
    init(count: Int) {
        guard count > 0 else { sectors = []; return }
        let outerCount = count <= 12 ? count : (count + 1) / 2
        let innerCount = count - outerCount
        var result: [Sector] = []
        for index in 0..<outerCount {
            result.append(Sector(index: index, inner: innerCount == 0 ? 88 : 158, outer: 228,
                                 angle: Double(index) * .pi * 2 / Double(outerCount), span: .pi * 2 / Double(outerCount)))
        }
        if innerCount > 0 {
            for index in 0..<innerCount {
                result.append(Sector(index: index + outerCount, inner: 82, outer: 151,
                                     angle: Double(index) * .pi * 2 / Double(innerCount), span: .pi * 2 / Double(innerCount)))
            }
        }
        sectors = result
    }
    func index(at point: CGPoint) -> Int? { sectors.first(where: { $0.contains(point) })?.index }
}

enum WheelChoice {
    case format(ConversionFormat), tool(FileTool), action(FileAction)
    var title: String {
        switch self { case .format(let value): return value.title; case .tool(let value): return value.title; case .action(let value): return value.title }
    }
    var symbol: String {
        switch self { case .format(let value): return value.symbol; case .tool: return "wand.and.stars"; case .action(let value): return value.symbol }
    }
}

@MainActor
private final class WheelAccessibilityTarget: NSAccessibilityElement {
    var press: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }; press(); return true
    }
}

@MainActor
final class RadialWheelView: NSView {
    let choices: [WheelChoice]
    let mode: ShelfMode
    let inputs: [URL]
    let shortcut: String
    let receive: ([URL], WheelChoice) -> Void
    let close: () -> Void
    let choose: (WheelChoice) -> Void
    private let layout: RadialWheelLayout
    private var highlighted: Int? { didSet { if oldValue != highlighted { needsDisplay = true } } }
    private var accessibilityTargets: [NSAccessibilityElement] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(choices: [WheelChoice], mode: ShelfMode, inputs: [URL], shortcut: String = "", receive: @escaping ([URL], WheelChoice) -> Void, close: @escaping () -> Void, choose: @escaping (WheelChoice) -> Void) {
        self.choices = choices; self.mode = mode; self.inputs = inputs; self.shortcut = shortcut; self.receive = receive; self.close = close; self.choose = choose
        layout = RadialWheelLayout(count: choices.count)
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        setAccessibilityRole(.group); setAccessibilityLabel("ShiftDrop " + mode.title + " wheel")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); rebuildAccessibility() }
    private func rebuildAccessibility() {
        accessibilityTargets = layout.sectors.map { sector in
            let element = WheelAccessibilityTarget()
            element.press = { [weak self] in guard let self else { return }; self.choose(self.choices[sector.index]) }
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("Drop files: " + choices[sector.index].title)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(NSRect(x: sector.center.x - 29, y: 480 - sector.center.y - 24, width: 58, height: 48))
            return element
        }
        setAccessibilityChildren(accessibilityTargets)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let ink = NSColor(srgbRed: 0.075, green: 0.13, blue: 0.10, alpha: 1)
        let lime = NSColor(srgbRed: 0.81, green: 0.98, blue: 0.42, alpha: 1)
        ink.withAlphaComponent(0.98).setFill(); NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 466, height: 466)).fill()
        for sector in layout.sectors {
            let path = NSBezierPath()
            let start = sector.angle - sector.span / 2 + 0.015
            let end = sector.angle + sector.span / 2 - 0.015
            for step in 0...32 {
                let angle = start + (end - start) * Double(step) / 32
                let point = CGPoint(x: 240 + sin(angle) * sector.outer, y: 240 - cos(angle) * sector.outer)
                if step == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            for step in (0...32).reversed() {
                let angle = start + (end - start) * Double(step) / 32
                path.line(to: CGPoint(x: 240 + sin(angle) * sector.inner, y: 240 - cos(angle) * sector.inner))
            }
            path.close()
            let selected = highlighted == sector.index
            (selected ? lime : NSColor.white.withAlphaComponent(0.065)).setFill(); path.fill()
            NSColor.white.withAlphaComponent(0.07).setStroke(); path.lineWidth = 0.6; path.stroke()
            let color = selected ? ink : NSColor.white
            let symbolSize: CGFloat = choices.count > 12 ? 15 : 19
            let center = sector.center
            if let image = NSImage(systemSymbolName: choices[sector.index].symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: symbolSize, weight: .medium)) {
                let tinted = image.copy() as! NSImage
                tinted.lockFocus(); color.setFill(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
                tinted.draw(in: NSRect(x: center.x - symbolSize / 2, y: center.y - 22, width: symbolSize, height: symbolSize))
            }
            label(choices[sector.index].title, in: NSRect(x: center.x - 37, y: center.y + 1, width: 74, height: 30), size: choices.count > 12 ? 10 : 11, color: color, weight: .semibold)
        }
        lime.setFill(); NSBezierPath(roundedRect: NSRect(x: 222, y: 192, width: 36, height: 36), xRadius: 10, yRadius: 10).fill()
        label("↘", in: NSRect(x: 223, y: 195, width: 34, height: 28), size: 25, color: ink, weight: .bold)
        label("ShiftDrop", in: NSRect(x: 176, y: 235, width: 128, height: 22), size: 17, color: .white, weight: .semibold)
        label((shortcut.isEmpty ? "" : shortcut + "  ") + mode.title.uppercased(), in: NSRect(x: 171, y: 262, width: 138, height: 18), size: 10, color: lime, weight: .semibold)
        let hint = inputs.isEmpty ? "Drop Finder files" : inputs.count == 1 ? inputs[0].lastPathComponent : "\(inputs.count) files"
        label(hint, in: NSRect(x: 175, y: 286, width: 130, height: 30), size: 10, color: .white.withAlphaComponent(0.65))
        if choices.isEmpty { label("No compatible formats", in: NSRect(x: 120, y: 140, width: 240, height: 30), size: 12, color: .white) }
    }
    private func label(_ string: String, in rect: NSRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
        (string as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        let values = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        var seen = Set<URL>(); return values.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = layout.index(at: convert(sender.draggingLocation, from: nil))
        return highlighted != nil && !urls(sender).isEmpty ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layout.index(at: convert(sender.draggingLocation, from: nil)) != nil && !urls(sender).isEmpty
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = layout.index(at: convert(sender.draggingLocation, from: nil)) else { return false }
        let files = urls(sender); guard !files.isEmpty else { return false }
        receive(files, choices[index]); return true
    }
    override func mouseDown(with event: NSEvent) {
        if let index = layout.index(at: convert(event.locationInWindow, from: nil)) { choose(choices[index]) }
        else { close() }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: close()
        case 123, 126:
            guard !choices.isEmpty else { return }; highlighted = ((highlighted ?? 0) + choices.count - 1) % choices.count
        case 124, 125, 48:
            guard !choices.isEmpty else { return }; highlighted = ((highlighted ?? -1) + 1) % choices.count
        case 36, 76:
            if let highlighted { choose(choices[highlighted]) }
        default: super.keyDown(with: event)
        }
    }
}
