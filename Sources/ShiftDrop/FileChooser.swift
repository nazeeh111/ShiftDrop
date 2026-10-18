import SwiftUI
import AppKit

@MainActor
final class FileChooserController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let completion: ([URL]) -> Void
    init(directory: URL, foldersOnly: Bool, completion: @escaping ([URL]) -> Void) {
        self.completion = completion
        super.init()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.window = window
        window.title = foldersOnly ? "Choose output folder" : "Add files to ShiftDrop"
        window.minSize = NSSize(width: 660, height: 450)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: FileChooserView(browser: FileBrowserModel(directory: directory), foldersOnly: foldersOnly, finish: { [weak self] urls in
            if let urls { self?.completion(urls) }
            self?.window?.close()
        }))
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    func close() { window?.close() }
}

struct BrowserEntry: Identifiable {
    let url: URL
    let directory: Bool
    var id: URL { url }
}

@MainActor
final class FileBrowserModel: ObservableObject {
    @Published var directory: URL
    @Published var path: String
    @Published var entries: [BrowserEntry] = []
    @Published var selection: Set<URL> = []
    @Published var error: String?
    @Published var loading = false
    init(directory: URL) {
        var start = directory
        while !FileManager.default.fileExists(atPath: start.path), start.path != "/" { start.deleteLastPathComponent() }
        self.directory = start
        self.path = start.path
        navigate(start)
    }
    func go() {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { navigate(url) }
        else if FileManager.default.fileExists(atPath: url.path) { navigate(url.deletingLastPathComponent()); selection = [url] }
        else { error = "That location does not exist or cannot be read." }
    }
    func navigate(_ url: URL) {
        directory = url; path = url.path; selection = []; entries = []; error = nil; loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[BrowserEntry], Error> = Result {
                    try FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }.map { name in
                        let entryURL = url.appendingPathComponent(name)
                        var isDirectory: ObjCBool = false
                        FileManager.default.fileExists(atPath: entryURL.path, isDirectory: &isDirectory)
                        return BrowserEntry(url: entryURL, directory: isDirectory.boolValue)
                    }.sorted {
                        if $0.directory != $1.directory { return $0.directory }
                        return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                    }
            }
            DispatchQueue.main.async {
                guard self.directory == url else { return }
                self.loading = false
                switch result { case .success(let entries): self.entries = entries; case .failure(let failure): self.entries = []; self.error = failure.localizedDescription }
            }
        }
    }
}

struct FileChooserView: View {
    @ObservedObject var browser: FileBrowserModel
    let foldersOnly: Bool
    let finish: ([URL]?) -> Void
    private var selected: [URL] { browser.selection.filter { FileManager.default.fileExists(atPath: $0.path) }.sorted { $0.path < $1.path } }
    private var outputFolder: URL {
        if selected.count == 1, let url = selected.first {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return url }
        }
        return browser.directory
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { browser.navigate(browser.directory.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }.help("Enclosing folder")
                TextField("Folder or file path", text: $browser.path).textFieldStyle(.roundedBorder).onSubmit(browser.go)
                Button("Go", action: browser.go)
            }.padding(16)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 17) {
                    Text("LOCATIONS").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(.muted)
                    location("Home", "house", FileManager.default.homeDirectoryForCurrentUser)
                    location("Downloads", "arrow.down.circle", FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
                    location("Desktop", "desktopcomputer", FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0])
                    location("Documents", "doc", FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
                    location("Volumes", "externaldrive", URL(fileURLWithPath: "/Volumes", isDirectory: true))
                    Spacer()
                    Text("⌘ click to select\nmultiple files.").font(.system(size: 10)).foregroundColor(.muted).lineSpacing(3)
                }.padding(20).frame(width: 150).background(Color.ink.opacity(0.035))
                Divider()
                VStack(spacing: 0) {
                    if browser.loading { ProgressView().padding() }
                    List(selection: $browser.selection) {
                        ForEach(browser.entries) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: entry.directory ? "folder.fill" : "doc").foregroundColor(entry.directory ? .muted : .ink.opacity(0.45)).frame(width: 22)
                                Text(entry.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if entry.directory {
                                    Button { browser.navigate(entry.url) } label: { Image(systemName: "chevron.right").padding(5) }.buttonStyle(.borderless).help("Open \(entry.url.lastPathComponent)")
                                }
                            }.padding(.vertical, 3).tag(entry.url)
                                .onTapGesture(count: 2) { if entry.directory { browser.navigate(entry.url) } }
                        }
                    }.listStyle(.inset)
                    if let error = browser.error { Text(error).font(.system(size: 11)).foregroundColor(.red).padding(12) }
                }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(foldersOnly ? "Save new files here" : "Files and folders stay on your Mac").font(.system(size: 11, weight: .medium))
                    Text(foldersOnly ? outputFolder.path : "\(selected.count) selected · folders can become ZIP archives").font(.system(size: 10)).foregroundColor(.muted)
                }
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button(foldersOnly ? "Use folder" : "Add selected") { finish(foldersOnly ? [outputFolder] : selected) }.keyboardShortcut(.defaultAction).disabled(browser.loading || browser.error != nil || (!foldersOnly && selected.isEmpty))
            }.padding(16)
        }.background(Color.paper).foregroundColor(.ink).preferredColorScheme(.light)
    }
    private func location(_ title: String, _ symbol: String, _ url: URL) -> some View {
        Button { browser.navigate(url) } label: { Label(title, systemImage: symbol).font(.system(size: 12)) }.buttonStyle(.plain)
    }
}
