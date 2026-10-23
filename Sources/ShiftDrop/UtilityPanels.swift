import AppKit
import SwiftUI

@MainActor
final class UtilityPanels {
    private let model: AppModel
    private var jobs: NSPanel?
    private var settings: NSWindow?
    private var guide: NSWindow?
    init(model: AppModel) { self.model = model }
    func showJobs(activate: Bool) {
        if jobs == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "ShiftDrop · Jobs"; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
            panel.level = .floating; panel.backgroundColor = NSColor(Color.paper)
            panel.contentView = NSHostingView(rootView: CompactJobsView(model: model))
            if let screen = NSScreen.main { let frame = screen.visibleFrame; panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 544, y: frame.maxY - 18)) }
            jobs = panel
        }
        if activate { jobs?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { jobs?.orderFrontRegardless() }
    }
    func showSettings() {
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ShiftDrop · Settings"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, close: { [weak window] in window?.close() })); window.center(); settings = window
        }
        settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showGuide() {
        if guide == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ShiftDrop · How it works"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HelpView(model: model, close: { [weak window] in window?.close() })); window.center(); guide = window
        }
        guide?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

struct CompactJobsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ShiftMark(size: 28)
                VStack(alignment: .leading, spacing: 3) { Text(model.running ? "Working locally" : "Ready for the next drop").font(.system(size: 15, weight: .semibold)); Text(model.backgroundStatus ?? "Drag a Finder file and hold Shift.").font(.system(size: 10)).foregroundColor(.muted).lineLimit(2) }
                Spacer()
                if model.running { Button("Cancel", action: model.cancel).controlSize(.small) }
            }
            if let notice = model.notice { Text(notice).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            ScrollView { LazyVStack(spacing: 9) {
                ForEach(Array(model.items.reversed())) { item in QueueRow(item: item, model: model) }
                if model.items.isEmpty { Text("No files are waiting. ShiftDrop stays out of the way until your next drag.").font(.system(size: 12)).foregroundColor(.muted).frame(maxWidth: .infinity).padding(.vertical, 35) }
            } }
            HStack {
                if model.readyCount > 0 { Button("Convert \(model.readyCount) waiting", action: model.run).disabled(model.running) }
                Spacer()
                if model.completeCount > 0 { Button("Clear completed", action: model.clearFinished) }
            }.controlSize(.small)
        }.padding(14).frame(width: 520, height: 360).background(Color.paper).foregroundColor(.ink).preferredColorScheme(.light)
    }
}
