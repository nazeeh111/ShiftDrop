import SwiftUI
import AppKit
import ShiftDropCore

extension Color {
    static let ink = Color(red: 0.075, green: 0.13, blue: 0.10)
    static let paper = Color(red: 0.966, green: 0.966, blue: 0.94)
    static let lime = Color(red: 0.81, green: 0.98, blue: 0.42)
    static let muted = Color(red: 0.40, green: 0.44, blue: 0.41)
    static let line = Color.ink.opacity(0.10)
}

struct ShiftMark: View {
    var size: CGFloat = 38
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25).fill(Color.lime)
            Image(systemName: "arrow.down.right").font(.system(size: size * 0.55, weight: .black)).foregroundColor(.ink)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct ActionButton: View {
    let title: String
    let symbol: String
    var prominent = false
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { Image(systemName: symbol); Text(title) }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundColor(prominent ? .ink : .ink)
                .background(prominent ? Color.lime : Color.white.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.line, lineWidth: 1))
        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.4 : 1)
    }
}

struct QueueRow: View {
    let item: QueueItem
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.input.path)).resizable().scaledToFit().frame(width: 36, height: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.input.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(FormatCatalog.kind(for: item.input))
                        Text("·")
                        Text(statusText)
                    }.font(.system(size: 10)).foregroundColor(item.state == .failed ? .red : .muted)
                }
                Spacer(minLength: 5)
                if item.state == .running { ProgressView().controlSize(.small) }
                else if item.state == .complete {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Color(red: 0.27, green: 0.48, blue: 0.22))
                    Button { model.reveal(item) } label: { Image(systemName: "folder") }.buttonStyle(.plain).help("Show converted files in Finder")
                } else {
                    Picker("Output format", selection: Binding(get: { item.format }, set: { model.setFormat(item.id, $0) })) {
                        ForEach(item.formats) { format in Text(format.title).tag(format) }
                    }.labelsHidden().frame(width: 100).disabled(item.state != .ready)
                }
                Menu {
                    Button("Reveal in Finder") { model.reveal(item) }
                    Button("Open file tools…") { model.showTools([item.input]) }
                    Menu("File actions") { ForEach(FileAction.allCases) { action in Button(action.title) { model.actions.perform(action, urls: item.result?.outputURLs ?? [item.input]) } } }
                    Button("Copy paths") { model.copyPaths(item) }
                    if item.state == .failed || item.state == .cancelled { Button("Retry") { model.retry(item.id) } }
                    Divider()
                    Button("Remove from queue") { model.remove(item.id) }.disabled(item.state == .running)
                } label: { Image(systemName: "ellipsis").frame(width: 18, height: 22) }.menuStyle(.borderlessButton).frame(width: 22)
            }
            if item.state == .ready, let note = FormatCatalog.note(for: item.input, to: item.format) { Text(note).font(.system(size: 10)).foregroundColor(.muted).fixedSize(horizontal: false, vertical: true) }
            if let message = item.message { Text(message).font(.system(size: 10)).foregroundColor(item.state == .failed ? .red : .muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            if let result = item.result {
                HStack { Image(systemName: "arrow.turn.down.right"); Text(result.outputURLs.count == 1 ? result.outputURLs[0].lastPathComponent : "\(result.outputURLs.count) output files").lineLimit(1).truncationMode(.middle); Spacer(); Text(AppModel.bytes(result.outputBytes)) }
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.muted).padding(.top, 1)
            }
        }.padding(16).foregroundColor(.ink).background(.white.opacity(0.85)).clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.line, lineWidth: 1))
    }
    private var statusText: String {
        switch item.state {
        case .ready: return "Ready → \(item.format.title)"
        case .running: return "Converting → \(item.format.title)"
        case .complete: return String(format: "Done · %.1fs", item.elapsed ?? 0)
        case .failed: return "Conversion failed"
        case .cancelled: return "Cancelled"
        }
    }
}

struct SettingsView: View {
    @AppStorage("revealCompletedFiles") private var revealCompletedFiles = true
    @ObservedObject var model: AppModel
    var close: () -> Void = {}
    private func modifierPicker(_ title: String, _ key: Binding<String>) -> some View { Picker(title, selection: key) { Text("Shift").tag("shift"); Text("Command").tag("command"); Text("Control").tag("control"); Text("Option").tag("option") } }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            HStack { ShiftMark(size: 30); Text("Make it your flow.").font(.system(size: 23, weight: .semibold)); Spacer() }
            Toggle("Enable modifier shortcuts while dragging files", isOn: $model.quickShelf).toggleStyle(.switch)
            HStack { modifierPicker("Convert", $model.convertKey); modifierPicker("Tools", $model.toolsKey); modifierPicker("Actions", $model.actionsKey) }
            if Set([model.convertKey, model.toolsKey, model.actionsKey]).count < 3 { Text("Choose a different modifier for each workflow. Duplicate shortcuts are disabled.").font(.system(size: 11)).foregroundColor(.red) }
            Toggle("Launch ShiftDrop at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
            Text("ShiftDrop starts quietly in the menu bar. It has no Dock icon or dashboard. Choose a file tool only when you need its controls.").font(.system(size: 11)).foregroundColor(.muted)
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Image quality").fontWeight(.medium); Spacer(); Text("\(Int(model.quality * 100))%").monospacedDigit() }
                Slider(value: $model.quality, in: 0.1...1, step: 0.05)
                Text("Used for JPEG and HEIC. PNG and TIFF remain lossless.").font(.system(size: 11)).foregroundColor(.muted)
            }
            Picker("Maximum image dimension", selection: $model.maxPixelSize) {
                Text("Original size").tag(0); Text("3840 pixels").tag(3840); Text("1920 pixels").tag(1920); Text("1280 pixels").tag(1280); Text("640 pixels").tag(640)
            }
            Text("Resizing fits inside this limit and preserves the image's proportions. Smaller images aren't enlarged. PDF pages use a bounded render size.").font(.system(size: 11)).foregroundColor(.muted)
            Toggle("Save converted copies beside their originals", isOn: $model.saveBesideOriginals)
            Toggle("Reveal completed conversions in Finder", isOn: $revealCompletedFiles)
            HStack { VStack(alignment: .leading, spacing: 4) { Text("Custom output folder").fontWeight(.medium); Text(model.outputDirectory.path).font(.system(size: 11)).foregroundColor(.muted).lineLimit(2).truncationMode(.middle) }; Spacer(); Button("Change…", action: model.chooseOutput) }
            Text("Settings apply to the next batch. Conversion history is kept only for this session.").font(.system(size: 11)).foregroundColor(.muted)
            HStack { Text("ShiftDrop 0.2.0").font(.system(size: 10, design: .monospaced)).foregroundColor(.muted); Spacer(); ActionButton(title: "Done", symbol: "checkmark", prominent: true) { close() }.keyboardShortcut(.defaultAction) }
        }.padding(30) }.frame(width: 600, height: 680).background(Color.paper).foregroundColor(.ink)
    }
}

struct HelpView: View {
    @ObservedObject var model: AppModel
    var close: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { ShiftMark(size: 32); Text("Stay in Finder.").font(.system(size: 26, weight: .semibold)) }
            Text("Drag a file. Hold Shift briefly. Drop on a format.").font(.system(size: 15, weight: .medium))
            Text("The wheel opens at your pointer. Release Shift and keep dragging; it stays available until you drop or cancel with Escape. Holding the key before starting a fresh drag also works.").font(.system(size: 13)).lineSpacing(4)
            Text("Command opens tools. Control opens file actions. Change those keys in Settings.").font(.system(size: 13)).lineSpacing(4)
            Text("Converted copies are saved beside each original by default. Existing files receive numbered names. Progress and results appear in a small job panel; closing it keeps the work running.").font(.system(size: 13)).lineSpacing(4)
            Text("ShiftDrop stays in the menu bar, including the first launch. Only settings, recent jobs and selected file editors open windows. Optional FFmpeg/ffprobe and LibreOffice enable additional routes. See the format guide on GitHub for fidelity limits.").font(.system(size: 12)).foregroundColor(.muted).lineSpacing(3)
            HStack { Label("Files are processed locally", systemImage: "lock.shield").font(.system(size: 11)); Spacer(); ActionButton(title: "Done", symbol: "checkmark", prominent: true, action: close) }
        }.padding(28).frame(width: 520).background(Color.paper).foregroundColor(.ink)
    }
}

enum FileDrop {
    @MainActor static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !accepted.isEmpty else { return false }
        let group = DispatchGroup()
        let collected = DropURLs()
        for (index, provider) in accepted.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { value, _ in
                defer { group.leave() }
                let url: URL?
                if let value = value as? URL { url = value }
                else if let data = value as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let text = value as? String { url = URL(string: text) }
                else { url = nil }
                if let url, url.isFileURL { collected.add(index, url) }
            }
        }
        group.notify(queue: .main) { completion(collected.urls) }
        return true
    }
}

private final class DropURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, URL)] = []
    func add(_ index: Int, _ url: URL) { lock.lock(); values.append((index, url)); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return values.sorted { $0.0 < $1.0 }.map(\.1) }
}
