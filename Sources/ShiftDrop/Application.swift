import AppKit
import SwiftUI
import ShiftDropCore
import Combine

@main
struct ShiftDropApp {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--help" {
            print("ShiftDrop 0.2.0\nA background Finder file utility.\nConvert: ShiftDrop --convert INPUT --to FORMAT --output DIRECTORY")
            return
        }
        if args.first == "--convert" { runCLI(args); return }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var shelf: DropShelf!
    private var panels: UtilityPanels!
    private var subscriptions = Set<AnyCancellable>()
    private var revealed = Set<UUID>()
    private var pendingFiles: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenu()
        panels = UtilityPanels(model: model)
        model.showWindow = { [weak self] in self?.panels.showJobs(activate: true) }
        shelf = DropShelf(model: model)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.down.right.square", accessibilityDescription: "ShiftDrop")
        statusItem.button?.toolTip = "ShiftDrop · Drag, hold Shift, drop"
        let menu = NSMenu()
        let summary = NSMenuItem(title: "Ready · drag a Finder file, then hold Shift", action: nil, keyEquivalent: "")
        summary.isEnabled = false; menu.addItem(summary); menu.addItem(.separator())
        menu.addItem(withTitle: "Show Convert Wheel", action: #selector(showShelf), keyEquivalent: "")
        menu.addItem(withTitle: "Show Tools Wheel", action: #selector(showToolsWheel), keyEquivalent: "")
        menu.addItem(withTitle: "Show Actions Wheel", action: #selector(showActionsWheel), keyEquivalent: "")
        menu.addItem(withTitle: "Recent Jobs…", action: #selector(showJobs), keyEquivalent: "")
        menu.addItem(withTitle: "File Tools…", action: #selector(showTools), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(preferences), keyEquivalent: ",")
        menu.addItem(withTitle: "How to use ShiftDrop…", action: #selector(showHelp), keyEquivalent: "")
        menu.addItem(withTitle: "Quit ShiftDrop", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        model.$backgroundStatus.sink { [weak self, weak summary] status in
            summary?.title = status ?? "Ready · drag a Finder file, then hold Shift"
            self?.statusItem.button?.toolTip = "ShiftDrop · " + (status ?? "Drag, hold Shift, drop")
        }.store(in: &subscriptions)
        model.$running.dropFirst().sink { [weak self] running in
            guard let self else { return }
            if running { self.panels.showJobs(activate: false) }
        }.store(in: &subscriptions)
        model.onStatus = { [weak self] _ in
            guard let self else { return }
            self.panels.showJobs(activate: false)
            guard !self.model.running else { return }
            let completed = self.model.items.filter { $0.state == .complete && !self.revealed.contains($0.id) }
            self.revealed.formUnion(completed.map(\.id))
            if UserDefaults.standard.object(forKey: "revealCompletedFiles") as? Bool ?? true {
                let outputs = completed.flatMap { $0.result?.outputURLs ?? [] }
                if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
            }
        }
        model.$notice.compactMap { $0 }.sink { [weak self] _ in self?.panels.showJobs(activate: false) }.store(in: &subscriptions)
        if !pendingFiles.isEmpty { shelf.show(at: NSEvent.mouseLocation, urls: pendingFiles, mode: .convert, manual: true); pendingFiles = [] }
        // Launch and relaunch stay silent, including the first launch. Editors and
        // settings are explicit menu actions, never a dashboard or Dock identity.
    }
    private func installMenu() {
        let menu = NSMenu(), app = NSMenuItem(); menu.addItem(app)
        let appMenu = NSMenu(); app.submenu = appMenu
        for (title, action, key) in [("Settings…", #selector(preferences), ","), ("Show Drop Wheel", #selector(showShelf), "d"), ("Recent Jobs…", #selector(showJobs), "j"), ("Quit ShiftDrop", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; appMenu.addItem(item)
        }
        let edit = NSMenuItem(); menu.addItem(edit); edit.title = "Edit"; edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key) }
        NSApp.mainMenu = menu
    }
    @objc func showShelf() { shelf.show(at: NSEvent.mouseLocation, urls: [], mode: .convert, manual: true) }
    @objc func showToolsWheel() { shelf.show(at: NSEvent.mouseLocation, urls: [], mode: .tools, manual: true) }
    @objc func showActionsWheel() { shelf.show(at: NSEvent.mouseLocation, urls: [], mode: .actions, manual: true) }
    @objc func showJobs() { panels.showJobs(activate: true) }
    @objc func showTools() { model.showTools() }
    @objc func preferences() { panels.showSettings() }
    @objc func showHelp() { panels.showGuide() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.running || model.toolsRunning || model.actions.moving else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Work is still running"
        alert.informativeText = model.actions.moving ? "Wait for the move to finish before quitting." : "Cancel conversions before quitting so unfinished output can be cleaned up safely."
        alert.addButton(withTitle: "Keep working"); alert.addButton(withTitle: "Cancel conversions")
        if alert.runModal() == .alertSecondButtonReturn { model.cancel(); model.cancelTools() }
        return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let files = filenames.map { URL(fileURLWithPath: $0) }
        if let shelf { shelf.show(at: NSEvent.mouseLocation, urls: files, mode: .convert, manual: true) }
        else { pendingFiles += files }
        sender.reply(toOpenOrPrint: .success)
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
private final class DropWheelPanel: NSPanel { override var canBecomeKey: Bool { true } }

@MainActor
final class DropShelf {
    private let panel: NSPanel
    private let model: AppModel
    private var timer: Timer?
    private var localKeys: Any?
    private var gesture = ShelfDragGesture()
    private var manual = false
    private var releasedAt: Date?
    private var chooser: FileChooserController?
    init(model: AppModel) {
        self.model = model
        panel = DropWheelPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 480), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "ShiftDrop · Drop wheel"
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        let polling = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        timer = polling; RunLoop.main.add(polling, forMode: .common)
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
        let urls = dragging && !flags.isEmpty ? (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [] : []
        let risingFlags = gesture.risingModifiers(mouseDown: dragging, pasteboardChangeCount: pasteboard.changeCount, flags: flags, hasFileURLs: !urls.isEmpty)
        if panel.isVisible, !manual {
            if !dragging {
                if let releasedAt, Date().timeIntervalSince(releasedAt) > 0.35 { hide() }
                else if releasedAt == nil { releasedAt = Date() }
            } else { releasedAt = nil }
        }
        guard model.quickShelf, dragging, Set([model.convertKey, model.toolsKey, model.actionsKey]).count == 3 else { return }
        let mapping: [(ShelfMode, String)] = [(.convert, model.convertKey), (.tools, model.toolsKey), (.actions, model.actionsKey)]
        guard let pair = mapping.first(where: { risingFlags.contains(key($0.1)) }), !urls.isEmpty else { return }
        show(at: NSEvent.mouseLocation, urls: urls, mode: pair.0, manual: false)
    }
    func show(at point: NSPoint, urls: [URL], mode: ShelfMode, manual: Bool) {
        self.manual = manual; releasedAt = nil
        let choices: [WheelChoice]
        switch mode {
        case .convert:
            let formats: [ConversionFormat]
            if let first = urls.first { formats = FormatCatalog.formats(for: first).filter { value in urls.allSatisfy { FormatCatalog.formats(for: $0).contains(value) } } }
            else { formats = [.png, .jpeg, .pdf, .mp4, .mp3, .txt, .vtt, .zip] }
            choices = formats.map(WheelChoice.format)
        case .tools: choices = (urls.isEmpty ? FileTool.allCases : FileTool.available(for: urls)).map(WheelChoice.tool)
        case .actions: choices = FileAction.allCases.map(WheelChoice.action)
        }
        let configuredKey = mode == .convert ? model.convertKey : mode == .tools ? model.toolsKey : model.actionsKey
        let shortcut = ["shift": "⇧", "command": "⌘", "control": "⌃", "option": "⌥"][configuredKey] ?? "⇧"
        panel.contentView = RadialWheelView(choices: choices, mode: mode, inputs: urls, shortcut: shortcut, receive: { [weak self] files, choice in self?.apply(choice, files: files) }, close: { [weak self] in self?.hide() }, choose: { [weak self] choice in
            guard let self else { return }
            if !urls.isEmpty { self.apply(choice, files: urls) }
            else {
                self.hide()
                self.chooser = FileChooserController(directory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0], foldersOnly: false) { [weak self] files in self?.apply(choice, files: files) }
            }
        })
        let visible = (NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel.setFrameOrigin(NSPoint(x: max(visible.minX + 8, min(point.x - 240, visible.maxX - 488)), y: max(visible.minY + 8, min(point.y - 240, visible.maxY - 488))))
        if manual { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(panel.contentView); NSApp.activate(ignoringOtherApps: true) }
        else { panel.orderFrontRegardless() }
    }
    private func apply(_ choice: WheelChoice, files: [URL]) {
        hide()
        switch choice {
        case .format(let format): model.addFiles(files, format: format, start: true, reveal: false)
        case .tool(let tool):
            guard FileTool.available(for: files).contains(tool) else { model.notice = "That tool cannot process these file types together."; return }
            model.showTools(files, tool: tool)
        case .action(let action): model.actions.perform(action, urls: files)
        }
    }
    func hide() { panel.orderOut(nil); manual = false; releasedAt = nil }
}
