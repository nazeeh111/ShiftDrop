import AppKit
import SwiftUI
import ShiftDropCore
import Combine

@main
struct ShiftDropApp {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--help" {
            print("ShiftDrop 0.1.1\nOpen app: ShiftDrop\nConvert: ShiftDrop --convert INPUT --to FORMAT --output DIRECTORY\nAvailable formats depend on input. Optional FFmpeg enables media.")
            return
        }
        if args.first == "--convert" { runCLI(args); return }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
    static func runCLI(_ args: [String]) {
        guard args.count == 6, args[2] == "--to", args[4] == "--output", let format = ConversionFormat(rawValue: args[3]) else {
            fputs("Usage: ShiftDrop --convert INPUT --to FORMAT --output DIRECTORY\n", stderr); exit(64)
        }
        Task {
            do {
                let result = try await ConversionEngine().convert(input: URL(fileURLWithPath: args[1]), to: format, outputDirectory: URL(fileURLWithPath: args[5], isDirectory: true))
                result.outputURLs.forEach { print($0.path) }; exit(0)
            } catch { fputs("ShiftDrop: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        dispatchMain()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var shelf: DropShelf!
    private var pendingExternalOpen = false
    private var statusSubscription: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "ShiftDrop"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(Color.paper)
        window.minSize = NSSize(width: 1080, height: 720)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MainView(model: model).padding(.top, 16).background(Color.paper))
        window.center()
        model.showWindow = { [weak self] in self?.showMain() }
        shelf = DropShelf(model: model)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.down.right.square", accessibilityDescription: "ShiftDrop")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open ShiftDrop", action: #selector(showMain), keyEquivalent: "")
        menu.addItem(withTitle: "Show Drop Shelf", action: #selector(showShelf), keyEquivalent: "")
        menu.addItem(withTitle: "File Tools…", action: #selector(showTools), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Preferences…", action: #selector(preferences), keyEquivalent: "")
        menu.addItem(withTitle: "Quit ShiftDrop", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        let summary = NSMenuItem(title: "Ready for a drop", action: nil, keyEquivalent: ""); summary.isEnabled = false
        menu.insertItem(summary, at: 0); menu.insertItem(.separator(), at: 1)
        statusItem.menu = menu
        statusItem.button?.toolTip = "ShiftDrop · Shift converts, Command tools, Control actions"
        statusSubscription = model.$backgroundStatus.sink { [weak self, weak summary] status in
            summary?.title = status ?? "Ready for a drop"
            self?.statusItem.button?.toolTip = "ShiftDrop · " + (status ?? "Ready for a drop")
        }
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
        UserDefaults.standard.set(true, forKey: "hasLaunched")
        if firstLaunch || !model.backgroundMode || pendingExternalOpen || !model.items.isEmpty { showMain() }
        else { NSApp.setActivationPolicy(.accessory) }
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
        if !paths.isEmpty { model.addFiles(paths.map { URL(fileURLWithPath: $0) }) }
    }
    func installMenu() {
        let menu = NSMenu()
        let app = NSMenuItem(); menu.addItem(app)
        let appMenu = NSMenu(); app.submenu = appMenu
        appMenu.addItem(withTitle: "About ShiftDrop", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(preferences), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ShiftDrop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit ShiftDrop", action: #selector(quit), keyEquivalent: "q")
        for item in appMenu.items where item.action != #selector(NSApplication.hide(_:)) { item.target = self }
        let file = NSMenuItem(); menu.addItem(file); file.submenu = NSMenu(title: "File"); file.title = "File"
        let add = NSMenuItem(title: "Add Files…", action: #selector(addFiles), keyEquivalent: "o"); add.target = self; file.submenu?.addItem(add)
        let convert = NSMenuItem(title: "Convert Ready Files", action: #selector(convertFiles), keyEquivalent: "\r"); convert.target = self; file.submenu?.addItem(convert)
        let toolsItem = NSMenuItem(title: "File Tools…", action: #selector(showTools), keyEquivalent: "t"); toolsItem.keyEquivalentModifierMask = [.command, .shift]; toolsItem.target = self; file.submenu?.addItem(toolsItem)
        let shelfItem = NSMenuItem(title: "Show Drop Shelf", action: #selector(showShelf), keyEquivalent: "d"); shelfItem.keyEquivalentModifierMask = [.command, .shift]; shelfItem.target = self; file.submenu?.addItem(shelfItem)
        file.submenu?.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenuItem(); menu.addItem(edit); edit.title = "Edit"; edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key) }
        let help = NSMenuItem(); menu.addItem(help); help.title = "Help"; help.submenu = NSMenu(title: "Help")
        let guide = NSMenuItem(title: "ShiftDrop Guide", action: #selector(showHelp), keyEquivalent: "?"); guide.target = self; help.submenu?.addItem(guide)
        NSApp.mainMenu = menu
    }
    @objc func showMain() { NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showShelf() { shelf.show(at: NSEvent.mouseLocation, urls: [], mode: .convert, manual: true) }
    @objc func showTools() { NSApp.setActivationPolicy(.regular); model.showTools() }
    func windowWillClose(_ notification: Notification) { if model.backgroundMode { NSApp.setActivationPolicy(.accessory) } }
    @objc func preferences() { showMain(); model.showSettings = true }
    @objc func showHelp() { showMain(); model.showHelp = true }
    @objc func addFiles() { showMain(); model.chooseFiles() }
    @objc func convertFiles() { model.run() }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "ShiftDrop", .applicationVersion: "0.1.1", .credits: NSAttributedString(string: "Files in. Flow out.\nAn offline conversion studio for your Mac.\n© 2026 Nazeeh Abdul-Hadi")]) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.running || model.toolsRunning || model.actions.moving else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Work is still running"
        alert.informativeText = model.actions.moving ? "Wait for the file move to finish before quitting. Active conversions can be cancelled safely." : "Cancel conversions before quitting so ShiftDrop can clean up unfinished output."
        alert.addButton(withTitle: "Keep working"); alert.addButton(withTitle: "Cancel conversions")
        if alert.runModal() == .alertSecondButtonReturn { model.cancel(); model.cancelTools() }
        return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMain(); return true }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        pendingExternalOpen = true
        model.addFiles(filenames.map { URL(fileURLWithPath: $0) }); sender.reply(toOpenOrPrint: .success)
    }
}

enum ShelfMode: String, CaseIterable, Identifiable {
    case convert, tools, actions
    var id: String { rawValue }
    var title: String { switch self { case .convert: return "Convert"; case .tools: return "Tools"; case .actions: return "Actions" } }
}

struct ShelfDragGesture {
    private var idlePasteboardChangeCount: Int?
    private var activePasteboardChangeCount: Int?
    private var deliveredFlags: NSEvent.ModifierFlags = []

    mutating func risingModifiers(mouseDown: Bool, pasteboardChangeCount: Int, flags: NSEvent.ModifierFlags, hasFileURLs: Bool = true) -> NSEvent.ModifierFlags {
        if !mouseDown {
            idlePasteboardChangeCount = pasteboardChangeCount
            activePasteboardChangeCount = nil
            deliveredFlags = []
            return []
        }
        // A mouse hold and old drag URLs are not a new drag. Wait for Finder to
        // publish fresh contents, without consuming a modifier pressed meanwhile.
        guard let idlePasteboardChangeCount, pasteboardChangeCount != idlePasteboardChangeCount else { return [] }
        if activePasteboardChangeCount != pasteboardChangeCount {
            activePasteboardChangeCount = pasteboardChangeCount
            deliveredFlags = []
        }
        // File promises may become readable after the pasteboard count changes.
        // Remember releases, but deliver a held modifier only once URLs are ready.
        deliveredFlags.formIntersection(flags)
        guard hasFileURLs else { return [] }
        let rising = flags.subtracting(deliveredFlags)
        deliveredFlags = flags
        return rising
    }
}

@MainActor
final class DropShelf {
    private let panel: NSPanel
    private let model: AppModel
    private var timer: Timer?
    private var localKeys: Any?
    private var gesture = ShelfDragGesture()
    private var manual = false
    private var releasedAt: Date?
    init(model: AppModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 410), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        let polling = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        timer = polling; RunLoop.main.add(polling, forMode: .common)
        // Polling public drag/modifier state needs no Accessibility or Input Monitoring permission.
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, self.panel.isVisible { self.hide(); return nil }; return event
        }
    }
    deinit { timer?.invalidate(); if let localKeys { NSEvent.removeMonitor(localKeys) } }
    private func key(_ string: String) -> NSEvent.ModifierFlags {
        switch string { case "command": return .command; case "control": return .control; case "option": return .option; default: return .shift }
    }
    private func poll() {
        let flags = NSEvent.modifierFlags.intersection([.shift, .command, .control, .option])
        let dragging = NSEvent.pressedMouseButtons & 1 != 0
        let pasteboard = NSPasteboard(name: .drag)
        let urls = dragging && !flags.isEmpty
            ? (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            : []
        let risingFlags = gesture.risingModifiers(mouseDown: dragging, pasteboardChangeCount: pasteboard.changeCount, flags: flags, hasFileURLs: !urls.isEmpty)
        if panel.isVisible, !manual {
            if !dragging {
                if let releasedAt, Date().timeIntervalSince(releasedAt) > 0.6 { hide() }
                else if releasedAt == nil { releasedAt = Date() }
            } else { releasedAt = nil }
        }
        guard model.quickShelf, dragging, Set([model.convertKey, model.toolsKey, model.actionsKey]).count == 3 else { return }
        let mapping: [(ShelfMode, String)] = [(.convert, model.convertKey), (.tools, model.toolsKey), (.actions, model.actionsKey)]
        guard let pair = mapping.first(where: { risingFlags.contains(key($0.1)) }) else { return }
        guard !urls.isEmpty else { return }
        show(at: NSEvent.mouseLocation, urls: urls, mode: pair.0, manual: false)
    }
    func show(at point: NSPoint, urls: [URL], mode: ShelfMode, manual: Bool) {
        self.manual = manual; releasedAt = nil
        let formats: [ConversionFormat]
        if let first = urls.first { formats = FormatCatalog.formats(for: first).filter { format in urls.allSatisfy { FormatCatalog.formats(for: $0).contains(format) } } }
        else { formats = [.png, .jpeg, .pdf, .mp4, .mp3, .txt, .vtt, .zip] }
        let tools = urls.isEmpty ? FileTool.allCases : FileTool.available(for: urls)
        panel.contentView = NSHostingView(rootView: ShelfView(initialMode: mode, formats: formats, tools: tools, convert: { [weak self] files, format in
            guard let self else { return }; self.hide(); self.model.addFiles(files, format: format, start: format != nil, reveal: format == nil)
        }, tool: { [weak self] files, tool in
            guard let self else { return }; self.hide()
            guard FileTool.available(for: files).contains(tool) else { self.model.notice = "That tool cannot process these file types together."; self.model.showWindow?(); return }
            NSApp.setActivationPolicy(.regular); self.model.showTools(files, tool: tool)
        }, action: { [weak self] files, action in self?.hide(); self?.model.actions.perform(action, urls: files) }, close: { [weak self] in self?.hide() }))
        let visible = (NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel.setFrameOrigin(NSPoint(x: max(visible.minX + 10, min(point.x - 260, visible.maxX - 530)), y: max(visible.minY + 10, min(point.y - 430, visible.maxY - 420))))
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil); manual = false; releasedAt = nil }
}

struct ShelfView: View {
    @State private var mode: ShelfMode
    let formats: [ConversionFormat]
    let tools: [FileTool]
    let convert: ([URL], ConversionFormat?) -> Void
    let tool: ([URL], FileTool) -> Void
    let action: ([URL], FileAction) -> Void
    let close: () -> Void
    @State private var queueTarget = false
    init(initialMode: ShelfMode, formats: [ConversionFormat], tools: [FileTool], convert: @escaping ([URL], ConversionFormat?) -> Void, tool: @escaping ([URL], FileTool) -> Void, action: @escaping ([URL], FileAction) -> Void, close: @escaping () -> Void) {
        _mode = State(initialValue: initialMode); self.formats = formats; self.tools = tools; self.convert = convert; self.tool = tool; self.action = action; self.close = close
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { ShiftMark(size: 27); Text("ShiftDrop").font(.system(size: 18, weight: .semibold)); Spacer(); Button(action: close) { Image(systemName: "xmark").font(.system(size: 12)) }.buttonStyle(.plain).help("Close shelf") }
            HStack(spacing: 6) { ForEach(ShelfMode.allCases) { value in Button { mode = value } label: { Text(value.title).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 9).foregroundColor(mode == value ? Color.ink : .white.opacity(0.65)).background(mode == value ? Color.lime : Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain) } }
            Text(mode == .convert ? "Drop on a format. Keep moving." : mode == .tools ? "Drop on a tool to open its controls." : "Drop files or folders onto an action.").font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    if mode == .convert { ForEach(formats) { format in ShelfDropTarget(title: format.title, symbol: format.symbol) { convert($0, format) } } }
                    else if mode == .tools { ForEach(tools) { choice in ShelfDropTarget(title: choice.title, symbol: "wand.and.stars") { tool($0, choice) } } }
                    else { ForEach(FileAction.allCases) { choice in ShelfDropTarget(title: choice.title, symbol: choice.symbol) { action($0, choice) } } }
                }
                if mode == .convert, formats.isEmpty { Text("No common format for this selection. Add to the queue to choose separately.").font(.system(size: 11)).foregroundColor(.white.opacity(0.65)).padding(12) }
            }
            Text("Add to studio queue →").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(queueTarget ? Color.lime.opacity(0.2) : Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 9))
                .onDrop(of: [.fileURL], isTargeted: $queueTarget) { providers in FileDrop.load(providers) { convert($0, nil) } }
        }.padding(22).frame(width: 520, height: 410).foregroundColor(.white).background(Color.ink).clipShape(RoundedRectangle(cornerRadius: 18)).preferredColorScheme(.dark)
    }
}
struct ShelfDropTarget: View {
    let title: String
    let symbol: String
    let receive: ([URL]) -> Void
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 7) { Image(systemName: symbol).font(.system(size: 17)); Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center) }
            .frame(maxWidth: .infinity).frame(height: 65).foregroundColor(targeted ? Color.ink : .white).background(targeted ? Color.lime : Color.white.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 9))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { FileDrop.load($0, completion: receive) }.accessibilityLabel("Drop files: " + title)
    }
}
