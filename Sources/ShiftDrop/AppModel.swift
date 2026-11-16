import AppKit
import SwiftUI
import ShiftDropCore
import ServiceManagement

struct QueueItem: Identifiable {
    enum State: String { case ready, running, complete, failed, cancelled }
    let id: UUID
    let input: URL
    var format: ConversionFormat
    var state: State = .ready
    var result: ConversionResult?
    var message: String?
    var elapsed: TimeInterval?
    var formats: [ConversionFormat] { FormatCatalog.formats(for: input).filter { QueueSession.supports(input: input, format: $0) } }
    init(input: URL, format: ConversionFormat, id: UUID = UUID()) { self.id = id; self.input = input; self.format = format }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [QueueItem] = []
    @Published var running = false
    @Published var filter = "All files"
    @Published var notice: String?
    @Published var saveBesideOriginals: Bool {
        didSet { defaults.set(saveBesideOriginals, forKey: "saveBesideOriginals") }
    }
    @Published var outputDirectory: URL {
        didSet { defaults.set(outputDirectory.path, forKey: "outputDirectory") }
    }
    @Published var quality: Double {
        didSet { defaults.set(quality, forKey: "quality") }
    }
    @Published var maxPixelSize = 0
    @Published var quickShelf: Bool {
        didSet { defaults.set(quickShelf, forKey: "quickShelf") }
    }
    @Published var convertKey: String { didSet { defaults.set(convertKey, forKey: "convertKey") } }
    @Published var toolsKey: String { didSet { defaults.set(toolsKey, forKey: "toolsKey") } }
    @Published var actionsKey: String { didSet { defaults.set(actionsKey, forKey: "actionsKey") } }
    @Published var loginEnabled: Bool
    lazy var actions = FileActions(model: self)
    private var toolStudio: ToolStudioController?
    private let defaults: UserDefaults
    private var queue: QueueSession?
    private var task: Task<Void, Never>?
    private var pendingQuickIDs: [UUID] = []
    @Published var backgroundStatus: String? {
        didSet { if let backgroundStatus { onStatus?(backgroundStatus) } }
    }
    var onStatus: ((String) -> Void)?
    private var fileChooser: FileChooserController?
    var showWindow: (() -> Void)?

    init(defaults: UserDefaults = .standard, queueDirectory: URL? = nil, checkLogin: Bool = true) {
        self.defaults = defaults
        loginEnabled = checkLogin ? SMAppService.mainApp.status == .enabled : false
        saveBesideOriginals = defaults.object(forKey: "saveBesideOriginals") == nil ? true : defaults.bool(forKey: "saveBesideOriginals")
        convertKey = defaults.string(forKey: "convertKey") ?? "shift"
        toolsKey = defaults.string(forKey: "toolsKey") ?? "command"
        actionsKey = defaults.string(forKey: "actionsKey") ?? "control"
        outputDirectory = defaults.string(forKey: "outputDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("ShiftDrop", isDirectory: true)
        quality = defaults.object(forKey: "quality") == nil ? 0.85 : min(1, max(0.1, defaults.double(forKey: "quality")))
        quickShelf = defaults.object(forKey: "quickShelf") == nil ? true : defaults.bool(forKey: "quickShelf")
        let root = queueDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ShiftDrop/Queue", isDirectory: true)
        do {
            let owner = try QueueSession(directory: root); queue = owner
            items = owner.jobs.map { job in
                var item = QueueItem(input: job.input, format: job.format, id: job.id)
                switch job.state {
                case .ready: item.state = .ready
                case .running, .prepared, .interrupted: item.state = .cancelled; item.message = job.message ?? "Interrupted. Review and retry explicitly."
                case .failed: item.state = .failed; item.message = job.message
                case .complete:
                    do { item.result = try job.recoverable ? owner.verifiedResult(job.id) : owner.oneShotResult(job.id); item.state = .complete; item.message = job.message }
                    catch { item.state = .failed; item.message = error.localizedDescription }
                }
                return item
            }
        } catch { notice = "Durable queue unavailable: \(error.localizedDescription)" }
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
        guard let queue else { notice = "Durable queue is unavailable. No files were added."; return }
        var skipped = 0
        var lastError: String?
        var oneShotAdded = false
        var added = 0
        var addedIDs: [UUID] = []
        for url in urls where url.isFileURL {
            let normalized = url.standardizedFileURL
            guard !items.contains(where: { $0.input == normalized && ($0.state == .ready || $0.state == .running) }) else { skipped += 1; continue }
            let formats = FormatCatalog.formats(for: normalized).filter { QueueSession.supports(input: normalized, format: $0) }
            guard let first = formats.first else { skipped += 1; continue }
            if let format, !formats.contains(format) { skipped += 1; continue }
            let preferred = format ?? (formats.contains(.png) ? .png : first)
            var item = QueueItem(input: normalized, format: preferred)
            do {
                let saved=try queue.enqueue(input: normalized, format: preferred, id: item.id)
                item.message=saved.message; oneShotAdded = oneShotAdded || !saved.recoverable
            } catch { skipped += 1; lastError = error.localizedDescription; continue }
            items.append(item)
            addedIDs.append(item.id)
            added += 1
        }
        filter = "All files"
        if skipped > 0 { notice = "Added \(added). Skipped \(skipped) duplicate, unsupported, or unavailable file\(skipped == 1 ? "" : "s"). \(lastError ?? "Choose supported files and formats.")" }
        else if oneShotAdded { notice = "Some operations are one-shot. After interruption, inspect the destination and create a new job." }
        else if added > 0 { notice = nil }
        if reveal { showWindow?() }
        if !reveal, skipped > 0, let notice { backgroundStatus = notice }
        if start && added > 0 {
            if running { pendingQuickIDs += addedIDs; backgroundStatus = "Quick drop queued. It will run after the active batch."; if !reveal { notice = nil } }
            else { run(only: addedIDs) }
        }
    }

    var toolsRunning: Bool { toolStudio?.model.running ?? false }
    func cancelTools() { toolStudio?.model.cancel() }
    func showTools(_ urls: [URL]? = nil, tool: FileTool? = nil) {
        if let toolStudio, toolStudio.model.running { toolStudio.show(); notice = "Finish or cancel the current tool operation first."; return }
        notice = "File Tools run separately; interrupted work and staging cleanup are not verified."
        let files = urls ?? items.filter { $0.state == .ready }.map(\.input)
        toolStudio?.close()
        toolStudio = ToolStudioController(inputs: files, tool: tool, destination: toolDestination(for: files), outputBesideInputs: saveBesideOriginals)
    }
    func destinationDirectory(for input: URL) -> URL {
        saveBesideOriginals ? input.deletingLastPathComponent() : outputDirectory
    }

    func toolDestination(for inputs: [URL]) -> URL {
        inputs.first.map { destinationDirectory(for: $0) } ?? outputDirectory
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
            if let url = urls.first {
                self?.outputDirectory = url
                self?.saveBesideOriginals = false
            }
        }
    }

    func setFormat(_ id: UUID, _ format: ConversionFormat) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .ready, items[i].formats.contains(format) else { return }
        do { try queue?.changeFormat(id, format: format); items[i].format = format; items[i].message = queue?.jobs.first(where: { $0.id == id })?.message } catch { notice = error.localizedDescription }
    }

    func applyToReady(_ format: ConversionFormat) {
        var count = 0
        for i in items.indices where items[i].state == .ready && items[i].formats.contains(format) {
            do { try queue?.changeFormat(items[i].id, format: format); items[i].format = format; items[i].message = queue?.jobs.first(where: { $0.id == items[i].id })?.message; count += 1 } catch { notice = error.localizedDescription }
        }
        notice = "Set \(count) compatible file\(count == 1 ? "" : "s") to \(format.title)."
    }

    func remove(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.state != .running else { return }
        do { try queue?.remove(id); items.removeAll { $0.id == id } } catch { notice = error.localizedDescription }
    }
    func clearFinished() { for item in items.filter({ $0.state == .complete }) { remove(item.id) } }
    func retry(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .failed || items[i].state == .cancelled else { return }
        do { try queue?.retry(id); items[i].state = .ready; items[i].message = nil } catch { notice = error.localizedDescription }
    }

    func cancel() { pendingQuickIDs = []; task?.cancel() }

    func run() { run(only: nil) }

    private func run(only selectedIDs: [UUID]?) {
        guard !running, readyCount > 0 else { return }
        let ids = items.filter { $0.state == .ready && (selectedIDs == nil || selectedIDs!.contains($0.id)) }.map(\.id)
        guard !ids.isEmpty else { return }
        let customDestination = outputDirectory
        let besideOriginals = saveBesideOriginals
        let options = ConversionOptions(quality: quality, maxPixelSize: maxPixelSize == 0 ? nil : maxPixelSize)
        running = true
        notice = nil
        guard let queue else { running = false; notice = "Durable queue unavailable."; return }
        task = Task { [weak self] in
            guard let self else { return }
            for id in ids {
                if Task.isCancelled { break }
                guard let index = self.items.firstIndex(where: { $0.id == id && $0.state == .ready }) else { continue }
                let input = self.items[index].input
                self.items[index].state = .running
                let began = Date()
                do {
                    let result = try await queue.execute(id, destination: besideOriginals ? input.deletingLastPathComponent() : customDestination, options: options)
                    if let current = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[current].result = result; self.items[current].state = .complete
                        self.items[current].message = queue.jobs.first(where: { $0.id == id })?.message
                        self.items[current].elapsed = Date().timeIntervalSince(began)
                    }
                } catch {
                    if let current = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[current].state = error is CancellationError || Task.isCancelled ? .cancelled : .failed
                        let reason=error.localizedDescription
                        if let note=queue.jobs.first(where: { $0.id == id })?.message, !reason.contains(note) {
                            self.items[current].message = reason + " " + note
                        } else { self.items[current].message = reason }
                    }
                }
            }
            self.running = false; self.task = nil
            self.backgroundStatus = "\(self.completeCount) complete · \(self.failedCount) need attention"
            let pending = self.pendingQuickIDs; self.pendingQuickIDs = []
            if !pending.isEmpty { self.run(only: pending) }
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
        let destination = saveBesideOriginals ? items.last.map { destinationDirectory(for: $0.input) } : outputDirectory
        guard let destination else { notice = "Drop a file to reveal its output folder."; return }
        if FileManager.default.fileExists(atPath: destination.path) { NSWorkspace.shared.open(destination) }
        else { notice = "Your output folder will be created when the first conversion runs." }
    }
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}
