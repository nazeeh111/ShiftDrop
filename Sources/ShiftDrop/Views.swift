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

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var targeted = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                Rectangle().fill(Color.line).frame(height: 1)
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.items.isEmpty { emptyState }
                        else { queue }
                        Spacer(minLength: 0)
                        footer
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(Color.line).frame(width: 1)
                    inspector.frame(width: 224)
                }
            }.background(Color.paper)
        }
        .frame(minWidth: 1040, minHeight: 650)
        .preferredColorScheme(.light)
        .onDrop(of: [.fileURL], isTargeted: $targeted, perform: receive)
        .overlay { if targeted { RoundedRectangle(cornerRadius: 12).stroke(Color.lime, lineWidth: 5).allowsHitTesting(false) } }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $model.showHelp) { HelpView(model: model) }
        .alert("ShiftDrop", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) { ShiftMark(size: 33); Text("ShiftDrop").font(.system(size: 20, weight: .bold, design: .rounded)).tracking(-0.6) }
                .padding(.top, 32).padding(.bottom, 38)
            Text("WORKSPACE").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(2).foregroundColor(.white.opacity(0.4)).padding(.bottom, 14)
            nav("All files", "square.stack.3d.up", model.items.count)
            nav("Ready", "circle.dotted", model.readyCount)
            nav("Completed", "checkmark.circle", model.completeCount)
            nav("Needs attention", "exclamationmark.circle", model.failedCount)
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: "shift").font(.system(size: 20, weight: .medium)); Spacer(); Circle().fill(model.quickShelf ? Color.lime : Color.gray).frame(width: 6, height: 6) }
                Text("A shortcut to done.").font(.system(size: 14, weight: .semibold))
                Text("Drag a file. Shift converts, Command opens tools, Control opens actions.")
                    .font(.system(size: 11)).lineSpacing(4).foregroundColor(.white.opacity(0.55))
                Button("How it works ↗") { model.showHelp = true }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(.lime)
            }.padding(16).background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 12))
            Button { model.showSettings = true } label: {
                HStack(spacing: 10) { Image(systemName: "slider.horizontal.3"); Text("Preferences"); Spacer(); Text("⌘,").font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.35)) }
            }.buttonStyle(.plain).font(.system(size: 12)).padding(.top, 26).padding(.bottom, 24)
            HStack(spacing: 6) { Image(systemName: "lock.shield"); Text("LOCAL BY DESIGN") }.font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.2).foregroundColor(.white.opacity(0.35)).padding(.bottom, 21)
        }.foregroundColor(.white).padding(.horizontal, 20).frame(width: 196).background(Color.ink)
    }
    private func nav(_ title: String, _ icon: String, _ count: Int) -> some View {
        Button { model.filter = title } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: model.filter == title ? .semibold : .regular))
                Spacer()
                Text("\(count)").font(.system(size: 10, design: .monospaced)).opacity(0.65)
            }.padding(.horizontal, 11).padding(.vertical, 11)
                .background(model.filter == title ? Color.lime.opacity(0.13) : .clear)
                .foregroundColor(model.filter == title ? .lime : .white.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).padding(.horizontal, -7).padding(.bottom, 3)
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("YOUR FILES. YOUR MAC.").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.7).foregroundColor(.muted)
                Text(model.filter == "All files" ? "Conversion studio" : model.filter).font(.system(size: 24, weight: .semibold)).tracking(-0.8)
            }
            Spacer()
            HStack(spacing: 6) { Circle().fill(Color.ink.opacity(0.65)).frame(width: 5, height: 5); Text("Offline").font(.system(size: 10, weight: .medium)) }.foregroundColor(.muted).padding(.trailing, 12)
            ActionButton(title: "Tools", symbol: "wand.and.stars") { model.showTools() }
            ActionButton(title: "Add files", symbol: "plus", action: model.chooseFiles).keyboardShortcut("o", modifiers: .command)
        }.foregroundColor(.ink).padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 24)
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("01 / DROP").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1).foregroundColor(.muted); Spacer(); Text("NO UPLOADS. NO ACCOUNTS.").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundColor(.muted) }.padding(.bottom, 26)
            Text("Files in.\nFlow out.").font(.system(size: 53, weight: .semibold)).tracking(-2.5).lineSpacing(-3).foregroundColor(.ink)
            Text("A better format is a drop away.").font(.system(size: 14)).foregroundColor(.muted).padding(.top, 14)
            Button(action: model.chooseFiles) {
                VStack(spacing: 16) {
                    ZStack { Circle().fill(Color.lime).frame(width: 54, height: 54); Image(systemName: "arrow.down.to.line").font(.system(size: 24, weight: .medium)).foregroundColor(.ink) }
                    VStack(spacing: 6) { Text("Drop files anywhere").font(.system(size: 16, weight: .semibold)).foregroundColor(.ink); Text("or click to choose from your Mac").font(.system(size: 12)).foregroundColor(.muted) }
                    HStack(spacing: 6) { tag("IMAGES"); tag("PDF"); tag("MEDIA"); tag("TEXT") }.padding(.top, 6)
                }.frame(maxWidth: .infinity).padding(.vertical, 30)
                    .background(Color.white.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.ink.opacity(0.20), style: StrokeStyle(lineWidth: 1, dash: [5,5])))
            }.buttonStyle(.plain).padding(.top, 29)
        }.padding(28)
    }
    private func tag(_ text: String) -> some View { Text(text).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(0.6).foregroundColor(.muted).padding(.horizontal, 9).padding(.vertical, 5).background(Color.ink.opacity(0.04)).clipShape(Capsule()) }
    private var queue: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(model.visibleItems.count) FILE\(model.visibleItems.count == 1 ? "" : "S")").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1)
                Spacer()
                if model.completeCount > 0 { Button("Clear completed", action: model.clearFinished).buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.muted) }
            }.foregroundColor(.muted).padding(.horizontal, 28).padding(.vertical, 20)
            if model.visibleItems.isEmpty {
                VStack(spacing: 10) { Image(systemName: "tray").font(.system(size: 28)).foregroundColor(.muted); Text("Nothing here yet").font(.system(size: 16, weight: .medium)); Text("Your files will appear here as you work.").font(.system(size: 12)).foregroundColor(.muted) }.frame(maxWidth: .infinity, maxHeight: .infinity).foregroundColor(.ink)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.visibleItems) { item in QueueRow(item: item, model: model) }
                    }.padding(.horizontal, 20).padding(.bottom, 18)
                }
            }
        }
    }
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.line).frame(height: 1)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.running ? "Converting on your Mac…" : model.readyCount > 0 ? "\(model.readyCount) ready to shift" : model.completeCount > 0 ? "All done. Keep your flow." : "Your originals stay untouched.")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(.ink)
                    Text(model.completeCount > 0 ? "\(model.completeCount) completed · \(AppModel.bytes(model.outputBytes)) written" : "New files. Same place in your day.")
                        .font(.system(size: 10)).foregroundColor(.muted)
                }
                Spacer()
                if model.running {
                    ProgressView().controlSize(.small).padding(.trailing, 5)
                    ActionButton(title: "Cancel", symbol: "stop", action: model.cancel)
                } else {
                    ActionButton(title: "Convert files", symbol: "arrow.down.right", prominent: true, disabled: model.readyCount == 0, action: model.run)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }.padding(22)
        }
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("THE OUTPUT").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundColor(.muted).padding(.bottom, 22)
            Label("Save to folder", systemImage: "folder").font(.system(size: 12, weight: .semibold)).padding(.bottom, 10)
            Text(model.outputDirectory.lastPathComponent).font(.system(size: 15, weight: .medium)).lineLimit(2)
            Text(model.outputDirectory.deletingLastPathComponent().path).font(.system(size: 10)).foregroundColor(.muted).lineLimit(2).truncationMode(.middle).padding(.top, 5).textSelection(.enabled)
            HStack(spacing: 14) { Button("Change…", action: model.chooseOutput); Button("Reveal", action: model.showOutputFolder) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).padding(.top, 14)
            Rectangle().fill(Color.line).frame(height: 1).padding(.vertical, 24)
            Text("QUICK PRESETS").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.3).foregroundColor(.muted).padding(.bottom, 14)
            preset("Shareable image", subtitle: "JPEG · smaller file", format: .jpeg, symbol: "photo")
            preset("Lossless image", subtitle: "PNG · keep detail", format: .png, symbol: "square.on.square")
            preset("Portable document", subtitle: "PDF · from an image", format: .pdf, symbol: "doc")
            preset("Bundle a file", subtitle: "ZIP · file or folder", format: .zip, symbol: "archivebox")
            Text("Applies to compatible ready files.").font(.system(size: 9)).foregroundColor(.muted).padding(.top, 5)
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 9) {
                HStack { Image(systemName: "waveform"); Text("Media engine").fontWeight(.medium) }.font(.system(size: 11))
                Text(FormatCatalog.ffmpegURL == nil ? "Optional FFmpeg isn't installed. Native image, PDF and text tools are ready." : "FFmpeg detected. Audio and video formats are ready.")
                    .font(.system(size: 10)).lineSpacing(3).foregroundColor(.muted)
                Button("Format guide ↗") { model.showHelp = true }.buttonStyle(.plain).font(.system(size: 10, weight: .medium))
            }.padding(13).background(Color.ink.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 9))
        }.foregroundColor(.ink).padding(22).background(Color.white.opacity(0.25))
    }
    private func preset(_ title: String, subtitle: String, format: ConversionFormat, symbol: String) -> some View {
        Button { model.applyToReady(format) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 26, height: 31).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 11, weight: .medium)); Text(subtitle).font(.system(size: 9)).foregroundColor(.muted) }
                Spacer(minLength: 0)
            }.padding(.vertical, 8).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.readyCount == 0).opacity(model.readyCount == 0 ? 0.55 : 1)
    }
    private func receive(_ providers: [NSItemProvider]) -> Bool {
        FileDrop.load(providers) { model.addFiles($0) }
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
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    private func modifierPicker(_ title: String, _ key: Binding<String>) -> some View { Picker(title, selection: key) { Text("Shift").tag("shift"); Text("Command").tag("command"); Text("Control").tag("control"); Text("Option").tag("option") } }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            HStack { ShiftMark(size: 30); Text("Make it your flow.").font(.system(size: 23, weight: .semibold)); Spacer() }
            Toggle("Enable modifier shortcuts while dragging files", isOn: $model.quickShelf).toggleStyle(.switch)
            HStack { modifierPicker("Convert", $model.convertKey); modifierPicker("Tools", $model.toolsKey); modifierPicker("Actions", $model.actionsKey) }
            if Set([model.convertKey, model.toolsKey, model.actionsKey]).count < 3 { Text("Choose a different modifier for each workflow. Duplicate shortcuts are disabled.").font(.system(size: 11)).foregroundColor(.red) }
            Toggle("Keep only the menu bar icon after closing the studio", isOn: $model.backgroundMode)
            Toggle("Launch ShiftDrop at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
            Text("The first launch shows the studio. Later launches start quietly in the menu bar when enabled. Open the studio from the menu bar at any time.").font(.system(size: 11)).foregroundColor(.muted)
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Image quality").fontWeight(.medium); Spacer(); Text("\(Int(model.quality * 100))%").monospacedDigit() }
                Slider(value: $model.quality, in: 0.1...1, step: 0.05)
                Text("Used for JPEG and HEIC. PNG and TIFF remain lossless.").font(.system(size: 11)).foregroundColor(.muted)
            }
            Picker("Maximum image dimension", selection: $model.maxPixelSize) {
                Text("Original size").tag(0); Text("3840 pixels").tag(3840); Text("1920 pixels").tag(1920); Text("1280 pixels").tag(1280); Text("640 pixels").tag(640)
            }
            Text("Resizing fits inside this limit and preserves the image's proportions. Smaller images aren't enlarged. PDF pages use a bounded render size.").font(.system(size: 11)).foregroundColor(.muted)
            HStack { VStack(alignment: .leading, spacing: 4) { Text("Output folder").fontWeight(.medium); Text(model.outputDirectory.path).font(.system(size: 11)).foregroundColor(.muted).lineLimit(2).truncationMode(.middle) }; Spacer(); Button("Change…", action: model.chooseOutput) }
            Text("Settings apply to the next batch. Conversion history is kept only for this session.").font(.system(size: 11)).foregroundColor(.muted)
            HStack { Text("ShiftDrop 0.1.1").font(.system(size: 10, design: .monospaced)).foregroundColor(.muted); Spacer(); ActionButton(title: "Done", symbol: "checkmark", prominent: true) { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(30) }.frame(width: 600, height: 680).background(Color.paper).foregroundColor(.ink)
    }
}

struct HelpView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("A small shift. A faster finish.").font(.system(size: 26, weight: .semibold)).tracking(-0.7)
            helpRow("01", "Add a file", "Drop Finder files onto the studio, choose Add files, or use Open With → ShiftDrop. Folders can be turned into ZIP archives.")
            helpRow("02", "Choose its next form", "Use each file's format menu, or apply a quick preset to compatible files. Choose an output folder and optional image size in Preferences.")
            helpRow("03", "Convert, then carry on", "Press ⌘ Return to convert. Reveal results in Finder, copy their paths, or retry a failed file. Existing files receive numbered names.")
            Divider()
            Text("The quick shelf").font(.system(size: 14, weight: .semibold))
            Text("Start dragging a file, then tap Shift for conversions, Command for tools, or Control for actions. Release the key and keep dragging; the shelf stays until you drop or cancel the Finder drag with Escape. Preferences lets you change the keys. A running batch queues new conversions for later. The menu bar and ⌘⇧D also open the shelf.").font(.system(size: 12)).lineSpacing(3)
            Text("Supported routes").font(.system(size: 14, weight: .semibold))
            Text("Native image, PDF, rich text, subtitle and archive routes work locally. FFmpeg and ffprobe enable media tools; LibreOffice enables spreadsheet and presentation conversions. The format menu shows routes available on this Mac. Animated image imports use the first frame for still outputs. PDF document exports reflow selectable text; slide exports use page images, and spreadsheet exports use text rows. Pages documents need Apple Pages, which is not integrated. See the format guide for exact limits.").font(.system(size: 12)).lineSpacing(3)
            HStack { Label("Processed on your Mac. No telemetry.", systemImage: "lock.shield").font(.system(size: 11)).foregroundColor(.muted); Spacer(); ActionButton(title: "Got it", symbol: "checkmark", prominent: true) { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(30).frame(width: 580).background(Color.paper).foregroundColor(.ink)
    }
    private func helpRow(_ n: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 18) { Text(n).font(.system(size: 11, design: .monospaced)).padding(8).background(Color.lime).clipShape(Circle()); VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 14, weight: .semibold)); Text(text).font(.system(size: 12)).foregroundColor(.muted).lineSpacing(3) } }
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
