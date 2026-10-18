import AppKit
import SwiftUI
import ShiftDropCore
import ServiceManagement

struct QueueItem: Identifiable {
    enum State: String { case ready, running, complete, failed, cancelled }
    let id = UUID()
    let input: URL
    var format: ConversionFormat
    var state: State = .ready
    var result: ConversionResult?
    var message: String?
    var elapsed: TimeInterval?
    var formats: [ConversionFormat] { FormatCatalog.formats(for: input) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [QueueItem] = []
    @Published var running = false
    @Published var filter = "All files"
    @Published var notice: String?
    @Published var showSettings = false
    @Published var showHelp = false
    @Published var outputDirectory: URL {
        didSet { UserDefaults.standard.set(outputDirectory.path, forKey: "outputDirectory") }
    }
    @Published var quality: Double {
        didSet { UserDefaults.standard.set(quality, forKey: "quality") }
    }
    @Published var maxPixelSize = 0
    @Published var quickShelf: Bool {
        didSet { UserDefaults.standard.set(quickShelf, forKey: "quickShelf") }
    }
    @Published var backgroundMode: Bool {
        didSet { UserDefaults.standard.set(backgroundMode, forKey: "backgroundMode") }
    }
    @Published var convertKey: String { didSet { UserDefaults.standard.set(convertKey, forKey: "convertKey") } }
    @Published var toolsKey: String { didSet { UserDefaults.standard.set(toolsKey, forKey: "toolsKey") } }
    @Published var actionsKey: String { didSet { UserDefaults.standard.set(actionsKey, forKey: "actionsKey") } }
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    lazy var actions = FileActions(model: self)
    private var toolStudio: ToolStudioController?
    private let engine = ConversionEngine()
    private var task: Task<Void, Never>?
    private var pendingQuickIDs: [UUID] = []
    @Published var backgroundStatus: String?
    private var fileChooser: FileChooserController?
    var showWindow: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        backgroundMode = defaults.object(forKey: "backgroundMode") == nil ? true : defaults.bool(forKey: "backgroundMode")
        convertKey = defaults.string(forKey: "convertKey") ?? "shift"
        toolsKey = defaults.string(forKey: "toolsKey") ?? "command"
        actionsKey = defaults.string(forKey: "actionsKey") ?? "control"
        outputDirectory = defaults.string(forKey: "outputDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("ShiftDrop", isDirectory: true)
        quality = defaults.object(forKey: "quality") == nil ? 0.85 : min(1, max(0.1, defaults.double(forKey: "quality")))
        quickShelf = defaults.object(forKey: "quickShelf") == nil ? true : defaults.bool(forKey: "quickShelf")
    }

    var readyCount: Int { items.filter { $0.state == .ready }.count }
    var completeCount: Int { items.filter { $0.state == .complete }.count }
    var failedCount: Int { items.filter { $0.state == .failed || $0.state == .cancelled }.count }
    var visibleItems: [QueueItem] {
        items.filter { item in
            switch filter {
            case "Ready": return item.state == .ready || item.state == .running
            case "Completed": return item.state == .complete
            case "Needs attention": return item.state == .failed || item.state == .cancelled
            default: return true
            }
        }
    }
    var outputBytes: Int64 { items.compactMap(\.result).reduce(0) { $0 + $1.outputBytes } }

    func addFiles(_ urls: [URL], format: ConversionFormat? = nil, start: Bool = false, reveal: Bool = true) {
        var skipped = 0
        var added = 0
        var addedIDs: [UUID] = []
        for url in urls where url.isFileURL {
            let normalized = url.standardizedFileURL
            guard !items.contains(where: { $0.input == normalized && ($0.state == .ready || $0.state == .running) }) else { skipped += 1; continue }
            let formats = FormatCatalog.formats(for: normalized)
            guard let first = formats.first else { skipped += 1; continue }
            if let format, !formats.contains(format) { skipped += 1; continue }
            let preferred = format ?? (formats.contains(.png) ? .png : first)
            let item = QueueItem(input: normalized, format: preferred)
            items.append(item)
            addedIDs.append(item.id)
            added += 1
        }
        filter = "All files"
        if skipped > 0 { notice = "Added \(added). Skipped \(skipped) duplicate or unsupported file\(skipped == 1 ? "" : "s")." }
        else if added > 0 { notice = nil }
        if reveal || (added == 0 && skipped > 0) { showWindow?() }
        if start && added > 0 {
            if running { pendingQuickIDs += addedIDs; backgroundStatus = "Quick drop queued. It will run after the active batch."; if !reveal { notice = nil } }
            else { run(only: addedIDs) }
        }
    }

    var toolsRunning: Bool { toolStudio?.model.running ?? false }
    func cancelTools() { toolStudio?.model.cancel() }
    func showTools(_ urls: [URL]? = nil, tool: FileTool? = nil) {
        if let toolStudio, toolStudio.model.running { toolStudio.show(); notice = "Finish or cancel the current tool operation first."; return }
        let files = urls ?? items.filter { $0.state == .ready }.map(\.input)
        toolStudio?.close()
        toolStudio = ToolStudioController(inputs: files, tool: tool, destination: outputDirectory)
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled { notice = "Approve ShiftDrop in System Settings → General → Login Items to finish enabling launch at login." }
        } catch { loginEnabled = SMAppService.mainApp.status == .enabled; notice = error.localizedDescription }
    }

    func chooseFiles() {
        fileChooser?.close()
        fileChooser = FileChooserController(directory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0], foldersOnly: false) { [weak self] urls in
            self?.addFiles(urls)
        }
    }

    func chooseOutput() {
        fileChooser?.close()
        fileChooser = FileChooserController(directory: outputDirectory, foldersOnly: true) { [weak self] urls in
            if let url = urls.first { self?.outputDirectory = url }
        }
    }

    func setFormat(_ id: UUID, _ format: ConversionFormat) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .ready, items[i].formats.contains(format) else { return }
        items[i].format = format
    }

    func applyToReady(_ format: ConversionFormat) {
        var count = 0
        for i in items.indices where items[i].state == .ready && items[i].formats.contains(format) {
            items[i].format = format; count += 1
        }
        notice = "Set \(count) compatible file\(count == 1 ? "" : "s") to \(format.title)."
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id && $0.state != .running } }
    func clearFinished() { items.removeAll { $0.state == .complete } }
    func retry(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .failed || items[i].state == .cancelled else { return }
        items[i].state = .ready; items[i].message = nil
    }

    func cancel() { pendingQuickIDs = []; task?.cancel() }

    func run() { run(only: nil) }

    private func run(only selectedIDs: [UUID]?) {
        guard !running, readyCount > 0 else { return }
        let ids = items.filter { $0.state == .ready && (selectedIDs == nil || selectedIDs!.contains($0.id)) }.map(\.id)
        guard !ids.isEmpty else { return }
        let destination = outputDirectory
        let options = ConversionOptions(quality: quality, maxPixelSize: maxPixelSize == 0 ? nil : maxPixelSize)
        running = true
        notice = nil
        let engine = self.engine
        task = Task.detached(priority: .userInitiated) { [weak self] in
            for id in ids {
                if Task.isCancelled { break }
                let job: (URL, ConversionFormat)? = await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let index = self.items.firstIndex(where: { $0.id == id && $0.state == .ready }) else { continuation.resume(returning: nil); return }
                        self.items[index].state = .running
                        continuation.resume(returning: (self.items[index].input, self.items[index].format))
                    }
                }
                guard let (input, format) = job else { continue }
                let began = Date()
                do {
                    let result = try await engine.convert(input: input, to: format, outputDirectory: destination, options: options)
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async { [weak self] in
                            if let self, let current = self.items.firstIndex(where: { $0.id == id }) {
                                self.items[current].result = result
                                self.items[current].state = .complete
                                self.items[current].elapsed = Date().timeIntervalSince(began)
                            }
                            continuation.resume()
                        }
                    }
                } catch {
                    let cancelled = error is CancellationError || Task.isCancelled
                    let message = cancelled ? "Cancelled. You can retry this file." : error.localizedDescription
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async { [weak self] in
                            if let self, let current = self.items.firstIndex(where: { $0.id == id }) {
                                self.items[current].state = cancelled ? .cancelled : .failed
                                self.items[current].message = message
                            }
                            continuation.resume()
                        }
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false; self.task = nil
                self.backgroundStatus = "\(self.completeCount) complete · \(self.failedCount) need attention"
                let pending = self.pendingQuickIDs; self.pendingQuickIDs = []
                if !pending.isEmpty { self.run(only: pending) }
            }
        }
    }

    func reveal(_ item: QueueItem) {
        NSWorkspace.shared.activateFileViewerSelecting(item.result?.outputURLs ?? [item.input])
    }
    func copyPaths(_ item: QueueItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((item.result?.outputURLs ?? [item.input]).map(\.path).joined(separator: "\n"), forType: .string)
        notice = "Copied file path\((item.result?.outputURLs.count ?? 1) > 1 ? "s" : "")."
    }
    func showOutputFolder() {
        if FileManager.default.fileExists(atPath: outputDirectory.path) { NSWorkspace.shared.open(outputDirectory) }
        else { notice = "Your output folder will be created when the first conversion runs." }
    }
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}
