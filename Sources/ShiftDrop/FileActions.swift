import AppKit
import SwiftUI
import ShiftDropCore

// Explicit user-selected actions, separate from conversion of new output files.
enum FileAction: String, CaseIterable, Identifiable {
    case airDrop, float, copy, move, copyPath, terminal
    var id: String { rawValue }
    var title: String {
        switch self { case .airDrop: return "AirDrop"; case .float: return "Float"; case .copy: return "Copy files"; case .move: return "Move…"; case .copyPath: return "Copy paths"; case .terminal: return "Terminal" }
    }
    var symbol: String {
        switch self { case .airDrop: return "airplayaudio"; case .float: return "rectangle.on.rectangle"; case .copy: return "doc.on.doc"; case .move: return "folder"; case .copyPath: return "link"; case .terminal: return "terminal" }
    }
}

@MainActor
final class FileActions {
    private weak var model: AppModel?
    private var floatWindow: NSPanel?
    private let floating = FloatingFilesModel()
    private var chooser: FileChooserController?
    private(set) var moving = false
    init(model: AppModel) { self.model = model }
    func perform(_ action: FileAction, urls: [URL]) {
        let urls = Array(NSOrderedSet(array: urls.filter(\.isFileURL))) as? [URL] ?? []
        guard !urls.isEmpty else { model?.notice = "Add a file or folder first."; return }
        switch action {
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { model?.notice = "AirDrop is unavailable for this selection on this Mac."; return }
            service.perform(withItems: urls)
        case .float:
            floating.add(urls)
            if floatWindow == nil {
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400), styleMask: [.titled, .closable, .utilityWindow, .resizable], backing: .buffered, defer: false)
                panel.title = "ShiftDrop · Floating files"; panel.isReleasedWhenClosed = false
                panel.level = .floating; panel.hidesOnDeactivate = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.contentView = NSHostingView(rootView: FloatingFilesView(model: floating, pin: { [weak panel] edge in
                    guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
                    let frame = screen.visibleFrame
                    panel.setFrameOrigin(NSPoint(x: edge == "left" ? frame.minX + 12 : frame.maxX - panel.frame.width - 12, y: frame.midY - panel.frame.height / 2))
                }))
                panel.center(); floatWindow = panel
            }
            floatWindow?.makeKeyAndOrderFront(nil)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            model?.notice = "Copied \(urls.count) file reference\(urls.count == 1 ? "" : "s"). Paste in Finder to copy the files."
        case .copyPath:
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            model?.notice = "Copied \(urls.count) path\(urls.count == 1 ? "" : "s")."
        case .terminal:
            let directories = Array(Set(urls.map { url in ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) ? url : url.deletingLastPathComponent() }))
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(directories, withApplicationAt: terminal, configuration: config) { [weak model] _, error in
                if let error { DispatchQueue.main.async { model?.notice = error.localizedDescription } }
            }
        case .move:
            guard !moving else { model?.notice = "Wait for the current move to finish."; return }
            chooser?.close()
            chooser = FileChooserController(directory: model?.outputDirectory ?? FileManager.default.homeDirectoryForCurrentUser, foldersOnly: true) { [weak self] destination in
                guard let self, let folder = destination.first else { return }
                let alert = NSAlert(); alert.messageText = "Move \(urls.count) original item\(urls.count == 1 ? "" : "s")?"
                alert.informativeText = "Destination: \(folder.path)\nThe originals will leave their current folders. Existing names receive numbered names."
                alert.addButton(withTitle: "Move originals"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                self.moving = true
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    do {
                        let moved = try FileTransfer.move(urls, to: folder)
                        DispatchQueue.main.async { self?.moving = false; self?.model?.notice = "Moved \(moved.count) item\(moved.count == 1 ? "" : "s") to \(folder.lastPathComponent)." }
                    } catch { DispatchQueue.main.async { self?.moving = false; self?.model?.notice = error.localizedDescription } }
                }
            }
        }
    }
}

@MainActor
final class FloatingFilesModel: ObservableObject {
    @Published var files: [URL] = []
    func add(_ urls: [URL]) { for url in urls where url.isFileURL && !files.contains(url) { files.append(url) } }
}
struct FloatingFilesView: View {
    @ObservedObject var model: FloatingFilesModel
    let pin: (String) -> Void
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { ShiftMark(size: 24); Text("Keep it within reach.").font(.headline); Spacer() }
            Text("Drop files here. Drag them into another app. Closing this shelf never deletes files.").font(.system(size: 11)).foregroundColor(.muted)
            List {
                ForEach(model.files, id: \.self) { url in
                    HStack { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24); Text(url.lastPathComponent).lineLimit(1); Spacer(); Button { model.files.removeAll { $0 == url } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove from shelf") }
                        .padding(.vertical, 5).onDrag { NSItemProvider(object: url as NSURL) }
                }
            }.listStyle(.plain)
            HStack { Button("Pin left") { pin("left") }; Button("Pin right") { pin("right") }; Spacer(); Button("Clear") { model.files = [] }.disabled(model.files.isEmpty) }.font(.system(size: 11))
        }.padding(18).frame(minWidth: 310, minHeight: 300).background(Color.paper).foregroundColor(.ink).preferredColorScheme(.light)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { FileDrop.load($0) { model.add($0) } }
            .overlay { if targeted { RoundedRectangle(cornerRadius: 8).stroke(Color.lime, lineWidth: 3).allowsHitTesting(false) } }
    }
}
