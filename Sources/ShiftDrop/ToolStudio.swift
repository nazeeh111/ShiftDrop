import AppKit
import SwiftUI
import PDFKit
import AVKit
import ImageIO
import ShiftDropCore

@MainActor
final class ToolStudioController: NSObject, NSWindowDelegate {
    let model: ToolStudioModel
    private var window: NSWindow!
    init(inputs: [URL], tool: FileTool?, destination: URL) {
        model = ToolStudioModel(inputs: inputs, tool: tool, destination: destination)
        super.init()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ShiftDrop · File tools"; window.isReleasedWhenClosed = false; window.delegate = self
        // Keep source image dimensions from becoming the window's preferred size.
        let hosting = NSHostingView(rootView: GeometryReader { [model = self.model] _ in ToolStudioView(model: model) })
        hosting.sizingOptions = []
        window.contentView = hosting; window.minSize = NSSize(width: 960, height: 650); window.setContentSize(NSSize(width: 1060, height: 760)); window.center(); show()
    }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func close() { if !model.running { window.close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.running { model.message = "Cancel the active operation before closing this tool window."; return false }; return true
    }
}

@MainActor
final class ToolStudioModel: ObservableObject {
    @Published var inputs: [URL]
    @Published var tool: FileTool
    @Published var settings = ToolSettings() {
        didSet { if !running { output = []; showingResult = false } }
    }
    @Published var selectedOutput = 0
    @Published var destination: URL
    @Published var running = false
    @Published var message: String?
    @Published var output: [URL] = []
    @Published var preview = false
    @Published var showingResult = false
    private var task: Task<Void, Never>?
    private var chooser: FileChooserController?
    private var previewDirectory: URL?
    var available: [FileTool] { FileTool.available(for: inputs) }
    init(inputs: [URL], tool: FileTool?, destination: URL) {
        self.inputs = inputs; self.tool = tool ?? FileTool.available(for: inputs).first ?? .compress; self.destination = destination
        resetDefaults()
    }
    deinit { if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) } }
    func resetDefaults() {
        var value = ToolSettings()
        if let first = inputs.first, FormatCatalog.kind(for: first) == "Image", let source = CGImageSourceCreateWithURL(first as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            value.width = min(16384, (properties[kCGImagePropertyPixelWidth] as? Int) ?? 1280)
            value.height = min(16384, (properties[kCGImagePropertyPixelHeight] as? Int) ?? 720)
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&value.width, &value.height) }
        }
        if [.annotateImage, .redactImage].contains(tool) { value.width = min(value.width, 400); value.height = min(value.height, 160); value.x = 20; value.y = 20 }
        value.end = 10
        settings = value; output = []; showingResult = false; message = nil
        if let first = inputs.first, ["Video", "Audio"].contains(FormatCatalog.kind(for: first)) {
            let selectedTool = tool
            Task.detached { [weak self] in
                guard let duration = try? await AVURLAsset(url: first).load(.duration), duration.seconds.isFinite, duration.seconds > 0 else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.inputs.first == first, self.tool == selectedTool, !self.running, self.settings.end == 10 else { return }
                    self.settings.end = duration.seconds
                }
            }
        }
    }
    func add(_ urls: [URL]) {
        guard !running else { return }
        for url in urls where url.isFileURL && !inputs.contains(url) { inputs.append(url) }
        if !available.contains(tool) { tool = available.first ?? .compress }
        resetDefaults()
    }
    func chooseInputs() {
        chooser = FileChooserController(directory: inputs.first?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser, foldersOnly: false) { [weak self] in self?.add($0) }
    }
    func chooseDestination() {
        chooser = FileChooserController(directory: destination, foldersOnly: true) { [weak self] in if let url = $0.first { self?.destination = url } }
    }
    func chooseBackground() {
        chooser = FileChooserController(directory: inputs.first?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser, foldersOnly: false) { [weak self] in if let url = $0.first { self?.settings.backgroundImage = url } }
    }
    func remove(_ index: Int) { guard !running else { return }; inputs.remove(at: index); if !available.contains(tool) { tool = available.first ?? .compress }; resetDefaults() }
    func move(_ index: Int, by delta: Int) { guard !running, inputs.indices.contains(index + delta) else { return }; inputs.swapAt(index, index + delta); output = []; showingResult = false }
    func cancel() { task?.cancel() }
    func run(preview: Bool) {
        guard !running, !inputs.isEmpty, available.contains(tool) else { return }
        let directory: URL
        if preview {
            if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("shiftdrop-preview-\(UUID().uuidString)", isDirectory: true)
            previewDirectory = scratch; directory = scratch
        } else { directory = destination }
        let request = ToolRequest(tool: tool, inputs: inputs, outputDirectory: directory, settings: settings)
        running = true; message = nil; self.preview = preview; output = []; showingResult = false; selectedOutput = 0
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try await FileToolEngine.run(request)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }; self.running = false; self.task = nil; self.output = result.outputURLs; self.showingResult = true
                    self.message = preview ? "Preview rendered from your actual settings. Save a copy to keep the result." : "Saved \(result.outputURLs.count) new file\(result.outputURLs.count == 1 ? "" : "s") · \(AppModel.bytes(result.outputBytes))."
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.running = false; self?.task = nil; self?.message = error is CancellationError ? "Cancelled. Original files are unchanged." : error.localizedDescription }
            }
        }
    }
}

struct ToolStudioView: View {
    @ObservedObject var model: ToolStudioModel
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ShiftMark(size: 32)
                VStack(alignment: .leading, spacing: 4) { Text("File tools").font(.system(size: 23, weight: .semibold)); Text("One useful change. A new copy.").font(.system(size: 11)).foregroundColor(.muted) }
                Spacer()
                Button("Add files…", action: model.chooseInputs).disabled(model.running)
            }.padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("INPUT ORDER").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.5).foregroundColor(.muted)
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(Array(model.inputs.enumerated()), id: \.element) { index, url in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack { Text("\(index + 1)").monospacedDigit().foregroundColor(.muted); Text(url.lastPathComponent).lineLimit(2).fontWeight(.medium); Spacer() }
                                    HStack { Button { model.move(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0); Button { model.move(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index + 1 == model.inputs.count); Spacer(); Button { model.remove(index) } label: { Image(systemName: "xmark") } }.buttonStyle(.borderless).foregroundColor(.muted)
                                }.font(.system(size: 10)).padding(10).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8)).disabled(model.running)
                            }
                        }
                    }
                    Text("Drop more files here. Reorder before combining.").font(.system(size: 10)).foregroundColor(.muted)
                }.padding(18).frame(width: 185)
                Divider()
                VStack(spacing: 14) {
                    HStack { Text(model.showingResult ? (model.preview ? "RENDERED PREVIEW" : "SAVED RESULT") : "ORIGINAL").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.2).foregroundColor(.muted); Spacer(); if !model.output.isEmpty { Button(model.showingResult ? "Show original" : "Show result") { model.showingResult.toggle() }.font(.system(size: 10)) } }
                    if model.showingResult && model.output.count > 1 {
                        Picker("Output", selection: $model.selectedOutput) { ForEach(Array(model.output.enumerated()), id: \.offset) { index, url in Text(url.lastPathComponent).tag(index) } }.font(.system(size: 10))
                    }
                    Group {
                        if !model.showingResult, [.cropImage, .redactImage, .annotateImage].contains(model.tool), let first = model.inputs.first, FormatCatalog.kind(for: first) == "Image" {
                            PixelSelectionPreview(url: first, freehand: model.tool == .annotateImage && ["freehand", "highlight"].contains(model.settings.annotation), settings: $model.settings).allowsHitTesting(!model.running)
                        } else { FilePreview(url: model.showingResult ? model.output.indices.contains(model.selectedOutput) ? model.output[model.selectedOutput] : model.output.first : model.inputs.first) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.ink.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 12))
                    if let message = model.message { Text(message).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).foregroundColor(.muted) }
                    if !model.output.isEmpty, !model.preview { Button("Reveal saved files in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.output) }.font(.system(size: 11)) }
                    Text(model.tool.explanation).font(.system(size: 10)).foregroundColor(.muted).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }.padding(20).frame(maxWidth: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("Tool", selection: $model.tool) { ForEach(model.available) { Text($0.title).tag($0) } }.onChange(of: model.tool) { _ in model.resetDefaults() }
                        Divider()
                        if model.tool == .organizePDF, let first = model.inputs.first { PDFPageOrganizer(url: first, settings: $model.settings) }
                        ToolSettingsView(tool: model.tool, settings: $model.settings, chooseBackground: model.chooseBackground)
                        Divider()
                        Text("SAVE TO").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1).foregroundColor(.muted)
                        Text(model.destination.path).font(.system(size: 10)).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                        Button("Change folder…", action: model.chooseDestination)
                    }.font(.system(size: 12)).padding(20)
                }.frame(width: 290).disabled(model.running)
            }
            Divider()
            HStack {
                Text(model.running ? "Working locally…" : "Your originals stay unchanged. Existing output names are numbered.").font(.system(size: 10)).foregroundColor(.muted)
                Spacer()
                if model.running { ProgressView().controlSize(.small); Button("Cancel", action: model.cancel) }
                else { Button("Render preview") { model.run(preview: true) }.disabled(model.inputs.isEmpty); ActionButton(title: "Save a copy", symbol: "arrow.down.right", prominent: true, disabled: model.inputs.isEmpty) { model.run(preview: false) } }
            }.padding(18)
        }.background(Color.paper).foregroundColor(.ink).preferredColorScheme(.light)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { FileDrop.load($0) { model.add($0) } }
            .overlay { if targeted { RoundedRectangle(cornerRadius: 10).stroke(Color.lime, lineWidth: 4).allowsHitTesting(false) } }
    }
}

struct ToolSettingsView: View {
    let tool: FileTool
    @Binding var settings: ToolSettings
    let chooseBackground: () -> Void
    @State private var selectedMark: Int?
    @State private var selectedRegion: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if [.cropImage, .cropVideo, .redactImage, .redactVideo, .annotateImage].contains(tool) {
                Text("Pixel rectangle · top-left origin").fontWeight(.medium)
                integer("Left", $settings.x); integer("Top", $settings.y)
            }
            if [.cropImage, .cropVideo, .redactImage, .redactVideo, .annotateImage, .frameImage, .collage, .audioVisualizer].contains(tool) { integer("Width", $settings.width); integer("Height", $settings.height) }
            if tool == .cropImage {
                Menu("Aspect ratio") {
                    Button("Square · 1:1") { settings.height = min(16384, max(1, settings.width)) }
                    Button("Landscape · 16:9") { settings.height = max(1, min(16384, max(1, settings.width)) * 9 / 16) }
                    Button("Portrait · 9:16") { settings.width = max(1, min(16384, max(1, settings.height)) * 9 / 16) }
                    Button("Photo · 3:2") { settings.height = max(1, min(16384, max(1, settings.width)) * 2 / 3) }
                    Button("Photo · 4:3") { settings.height = max(1, min(16384, max(1, settings.width)) * 3 / 4) }
                }
                Text("Draw on the preview or enter exact pixels. Ratios adjust the draft rectangle; preview before saving.").font(.system(size: 10)).foregroundColor(.muted)
            }
            if tool == .compress {
                scalar("Quality", $settings.quality, 0.05...1)
                integer("Max width", $settings.width); integer("Max height", $settings.height)
                HStack { Text("Target KB (0 = automatic)"); Spacer(); TextField("0 = quality", value: Binding(get: { Int(settings.targetBytes / 1024) }, set: { settings.targetBytes = Int64(max(0, min($0, 1_000_000))) * 1024 }), format: .number).frame(width: 90) }
                Text("Target size applies to images and media. Image bounds preserve proportions; PDF uses max width. Native PDF compression rasterizes pages: selectable text, forms, links and vector detail are lost in the new copy. Preview first. General files use ZIP.").font(.system(size: 10)).foregroundColor(.muted)
            }
            if tool == .metadata {
                Toggle("Remove metadata in new copy", isOn: $settings.removeMetadata)
                TextField("Optional title", text: $settings.metadataTitle)
                Text("Turn removal off with an empty title to inspect. General files produce a file-information report. Metadata cleaning does not certify removal of every embedded identifier.").font(.system(size: 10)).foregroundColor(.muted)
            }
            if tool == .editImage {
                scalar("Exposure", $settings.exposure, -3...3); scalar("Saturation", $settings.saturation, 0...2); scalar("Contrast", $settings.contrast, 0.5...2); scalar("Brightness", $settings.brightness, -1...1); scalar("Sharpness", $settings.sharpness, 0...2); scalar("Noise reduction", $settings.noiseReduction, 0...1); scalar("Dehaze tone", $settings.dehaze, 0...1); scalar("Clarity", $settings.clarity, 0...1); scalar("Grain", $settings.grain, 0...1)
            }
            if tool == .annotateImage {
                Picker("Mark", selection: $settings.annotation) { Text("Text").tag("text"); Text("Arrow").tag("arrow"); Text("Rectangle").tag("rectangle"); Text("Ellipse").tag("ellipse"); Text("Numbered marker").tag("marker"); Text("Magnifier").tag("magnifier"); Text("Image overlay").tag("overlay"); Text("Freehand").tag("freehand"); Text("Highlight").tag("highlight") }
                if settings.annotation == "overlay" { Button(settings.backgroundImage?.lastPathComponent ?? "Choose overlay image…", action: chooseBackground) }
                if ["freehand", "highlight"].contains(settings.annotation) { Text("Draw a path on the original preview. Add it as a layer to keep it while drawing another.").font(.system(size: 10)).foregroundColor(.muted) }
                TextField("Label", text: $settings.text); scalar("Font size", $settings.fontSize, 8...160); scalar("Line width", $settings.lineWidth, 1...30)
                TextField("Ink hex · RRGGBB", text: $settings.colorHex)
                if settings.annotation == "arrow" { Picker("Direction", selection: $settings.rotation) { Text("↘").tag(0); Text("↙").tag(90); Text("↖").tag(180); Text("↗").tag(270) } }
                annotationLayers
            }
            if [.frameImage, .collage].contains(tool) {
                integer("Spacing", $settings.padding); integer("Corner radius", $settings.cornerRadius)
                if tool == .frameImage { scalar("Background blur", $settings.frameBlur, 0...100); scalar("Shadow", $settings.frameShadow, 0...100) }
                TextField("Background hex", text: $settings.backgroundHex)
                if tool == .collage { integer("Columns", $settings.columns); Text("Width and height are the dimensions of each cell.").font(.system(size: 10)).foregroundColor(.muted) }
                if tool == .frameImage { Button(settings.backgroundImage?.lastPathComponent ?? "Choose background image…", action: chooseBackground); if settings.backgroundImage != nil { Button("Use solid background") { settings.backgroundImage = nil } } }
            }
            if [.redactImage, .redactVideo].contains(tool) {
                Toggle("Blur instead of solid cover", isOn: $settings.blur)
                TextField("Cover hex", text: $settings.colorHex)
                Text("Solid cover is the default. Blur can leave recognizable information. Inspect the exported result before sharing.").font(.system(size: 10)).foregroundColor(.muted)
                if tool == .redactImage { Toggle("Detect faces locally", isOn: $settings.detectFaces); Toggle("Detect text locally", isOn: $settings.detectText); Text("Detected regions and stored manual regions are combined. With no stored regions or detection, the draft rectangle is used. Detection can miss private content.").font(.system(size: 10)).foregroundColor(.muted) }
                else { Toggle("Only selected time range", isOn: $settings.limitTimeRange) }
                if tool == .redactImage { redactionRegions }
            }
            if [.trimVideo, .trimAudio, .bleepAudio, .videoFrames, .redactVideo].contains(tool) {
                decimal(tool == .videoFrames ? "First frame at (s)" : "Start (s)", $settings.start)
                decimal(tool == .videoFrames ? "Last frame before (s)" : "End (s)", $settings.end)
            }
            if [.trimAudio, .normalizeAudio].contains(tool) { Toggle("Remove edge silence", isOn: $settings.removeSilence) }
            if tool == .videoSpeed { scalar("Speed", $settings.speed, 0.25...4); Text("Audio pitch is preserved; silent videos are supported.").font(.system(size: 10)).foregroundColor(.muted) }
            if tool == .splitVideo { TextField("Split points in seconds · e.g. 2.5,8", text: $settings.splitPoints); integer("Equal parts if points empty", $settings.parts); Text("Clips are re-encoded at precise boundaries.").font(.system(size: 10)).foregroundColor(.muted) }
            if tool == .videoFrames { integer("Frame count", $settings.parts); Text("PNG snapshots are evenly spaced across the chosen time range.").font(.system(size: 10)).foregroundColor(.muted) }
            if tool == .normalizeAudio { decimal("Target LUFS", $settings.loudness); decimal("True peak dBTP", $settings.truePeak); decimal("Loudness range", $settings.loudnessRange); Text("LUFS measures perceived loudness; true peak limits peaks after playback reconstruction.").font(.system(size: 10)).foregroundColor(.muted) }
            if tool == .audioChannels { Picker("Channels", selection: $settings.channels) { Text("Mono").tag(1); Text("Stereo").tag(2) }; scalar("Left gain", $settings.leftGain, 0...2); scalar("Right gain", $settings.rightGain, 0...2)
                HStack { Button("Solo left preview") { settings.channels = 2; settings.leftGain = 1; settings.rightGain = 0 }; Button("Solo right preview") { settings.channels = 2; settings.leftGain = 0; settings.rightGain = 1 } }
                Button("Restore both channels") { settings.leftGain = 1; settings.rightGain = 1 }
                Text("Solo sets the actual output gains. Render and play the preview, then restore both channels before saving if desired.").font(.system(size: 10)).foregroundColor(.muted)
            }
            if tool == .audioVisualizer { Toggle("Animated waveform", isOn: $settings.waveform); TextField("Background hex", text: $settings.backgroundHex); TextField("Waveform hex", text: $settings.colorHex); Button(settings.backgroundImage?.lastPathComponent ?? "Choose still image…", action: chooseBackground) }
            if tool == .organizePDF {
                TextField("Page order, e.g. 3,1,2,2", text: $settings.pageOrder)
                Text("Use 1-based page numbers, ranges such as 1-3, and repeats. Omit a page to remove it from the new copy. Empty keeps all pages.").font(.system(size: 10)).foregroundColor(.muted)
                TextField("Output-page rotation · 1:90,3:180", text: $settings.pageRotations)
                Picker("Rotate all selected pages", selection: $settings.rotation) { Text("0°").tag(0); Text("90°").tag(90); Text("180°").tag(180); Text("270°").tag(270) }
            }
            if tool.requiresMultiple { Text("Inputs combine in the order shown at left. Move them up or down before saving.").font(.system(size: 10)).foregroundColor(.muted) }
        }.textFieldStyle(.roundedBorder)
    }
    private var draftRegion: ToolRegion { ToolRegion(x: settings.x, y: settings.y, width: settings.width, height: settings.height) }
    private var draftMark: ImageMark { ImageMark(kind: settings.annotation, region: draftRegion, text: settings.text, colorHex: settings.colorHex, fontSize: settings.fontSize, lineWidth: settings.lineWidth, rotation: settings.rotation, points: settings.points, imageURL: settings.backgroundImage) }
    private var annotationLayers: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Button("Add layer") { settings.marks.append(draftMark); selectedMark = settings.marks.count - 1 }; if let selectedMark, settings.marks.indices.contains(selectedMark) { Button("Update selected") { settings.marks[selectedMark] = draftMark } } }
            ForEach(Array(settings.marks.enumerated()), id: \.offset) { index, mark in
                HStack {
                    Button("\(index + 1) · \(mark.kind)") { selectedMark = index; settings.annotation = mark.kind; settings.x = mark.region.x; settings.y = mark.region.y; settings.width = mark.region.width; settings.height = mark.region.height; settings.text = mark.text; settings.colorHex = mark.colorHex; settings.fontSize = mark.fontSize; settings.lineWidth = mark.lineWidth; settings.rotation = mark.rotation; settings.points = mark.points; settings.backgroundImage = mark.imageURL }.buttonStyle(.plain).fontWeight(selectedMark == index ? .bold : .regular)
                    Spacer()
                    Button { if index > 0 { settings.marks.swapAt(index, index - 1); selectedMark = index - 1 } } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                    Button { settings.marks.remove(at: index); selectedMark = nil } label: { Image(systemName: "xmark") }
                }.font(.system(size: 10)).buttonStyle(.borderless)
            }
            Text(settings.marks.isEmpty ? "The draft is exported directly. Add layers to combine marks." : "Stored layers are exported in order. Add or update the draft before rendering.").font(.system(size: 10)).foregroundColor(.muted)
        }
    }
    private var redactionRegions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Button("Add cover region") { settings.regions.append(draftRegion); selectedRegion = settings.regions.count - 1 }; if let selectedRegion, settings.regions.indices.contains(selectedRegion) { Button("Update") { settings.regions[selectedRegion] = draftRegion } } }
            ForEach(Array(settings.regions.enumerated()), id: \.offset) { index, region in
                HStack {
                    Button("Cover \(index + 1) · \(region.width)×\(region.height)") { selectedRegion = index; settings.x = region.x; settings.y = region.y; settings.width = region.width; settings.height = region.height }.buttonStyle(.plain)
                    Spacer(); Button { settings.regions.remove(at: index); selectedRegion = nil } label: { Image(systemName: "xmark") }
                }.font(.system(size: 10)).buttonStyle(.borderless)
            }
            Text("Select a cover to move it by drawing again, then Update. Stored covers are all applied.").font(.system(size: 10)).foregroundColor(.muted)
        }
    }
    private func integer(_ title: String, _ binding: Binding<Int>) -> some View { HStack { Text(title); Spacer(); TextField(title, value: binding, format: .number).frame(width: 88).multilineTextAlignment(.trailing) } }
    private func decimal(_ title: String, _ binding: Binding<Double>) -> some View { HStack { Text(title); Spacer(); TextField(title, value: binding, format: .number).frame(width: 88).multilineTextAlignment(.trailing) } }
    private func scalar(_ title: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) { HStack { Text(title); Spacer(); Text(binding.wrappedValue, format: .number.precision(.fractionLength(2))).monospacedDigit().foregroundColor(.muted) }; Slider(value: binding, in: range) }
    }
}

struct FilePreview: View, Equatable {
    let url: URL?
    var body: some View {
        Group {
            if let url {
                if let image = thumbnail(url) { GeometryReader { geometry in Image(nsImage: image).resizable().scaledToFit().frame(width: max(1, geometry.size.width - 24), height: max(1, geometry.size.height - 24)).padding(12) } }
                else if url.pathExtension.lowercased() == "pdf" { PDFPreview(url: url) }
                else if ["Video", "Audio"].contains(FormatCatalog.kind(for: url)) { VideoPlayer(player: AVPlayer(url: url)).id(url) }
                else if url.pathExtension.lowercased() == "json" { MetadataReportPreview(url: url) }
                else if ["txt", "md", "html", "vtt", "srt", "rtf"].contains(url.pathExtension.lowercased()) { ScrollView { Text(text(url)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) } }
                else { VStack(spacing: 14) { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().frame(width: 70, height: 70); Text(url.lastPathComponent).font(.system(size: 12)).multilineTextAlignment(.center) } }
            } else { VStack(spacing: 12) { Image(systemName: "wand.and.stars").font(.system(size: 35)); Text("Drop files or choose Add files.").font(.system(size: 12)) }.foregroundColor(.muted) }
        }
    }
    private func thumbnail(_ url: URL) -> NSImage? {
        guard FormatCatalog.kind(for: url) == "Image", let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1200, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
    private func text(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "Preview unavailable." }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 200_000)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "Preview unavailable for this encoding."
    }
}
struct MetadataReportPreview: View {
    let url: URL
    @State private var query = ""
    @State private var rows: [(String, String)] = []
    @State private var unavailable = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search fields and values", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) || $0.1.localizedCaseInsensitiveContains(query) }.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 3) { Text(row.0).font(.system(size: 10, weight: .semibold)); Text(row.1).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                    if unavailable { Text("Report preview unavailable.") }
                }
            }
        }.padding(16).onAppear(perform: load).onChange(of: url) { _ in load() }
    }
    private func load() {
        rows = []; unavailable = false
        guard let handle = try? FileHandle(forReadingFrom: url) else { unavailable = true; return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2_000_000), let object = try? JSONSerialization.jsonObject(with: data) else { unavailable = true; return }
        func flatten(_ value: Any, path: String) {
            if let dictionary = value as? [String: Any] { for key in dictionary.keys.sorted() { flatten(dictionary[key]!, path: path.isEmpty ? key : path + " · " + key) } }
            else if let array = value as? [Any] { for (index, entry) in array.enumerated() { flatten(entry, path: path + "[\(index)]") } }
            else { rows.append((path, String(describing: value))) }
        }
        flatten(object, path: "")
    }
}
struct PDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.document = PDFDocument(url: url); return view }
    func updateNSView(_ view: PDFView, context: Context) { if view.document?.documentURL != url { view.document = PDFDocument(url: url) } }
}

extension FileTool {
    var explanation: String {
        switch self {
        case .compress: return "Compression makes a new copy. Compare quality and size before keeping it; a smaller size is not guaranteed for every source."
        case .metadata: return "Inspect or change metadata in a new copy. General file reports show filesystem information; this is not forensic sanitization."
        case .redactImage, .redactVideo: return "Redaction is flattened into exported pixels. Solid covers are safer than blur. Review every output before sharing."
        case .mergePDF, .imagesPDF: return "Combine all inputs into one PDF in the displayed order."
        case .organizePDF: return "Reorder, repeat, remove and rotate pages in a new PDF."
        case .joinVideo: return "Join clips in displayed order. Video is re-encoded to a common canvas."
        default: return "Render preview uses the same processing as Save a copy, in temporary storage. Source files are preserved."
        }
    }
}


/// Maps a drawn rectangle from the fitted preview into upright source pixels.
struct PixelSelectionPreview: View {
    let url: URL
    let freehand: Bool
    @Binding var settings: ToolSettings
    @State private var drawing = false
    @State private var thumbnail: CGImage?
    @State private var pixels = CGSize.zero
    var body: some View {
        GeometryReader { geometry in
            if let thumbnail, pixels.width > 0, pixels.height > 0 {
                let factor = min(geometry.size.width / pixels.width, geometry.size.height / pixels.height)
                let display = CGSize(width: pixels.width * factor, height: pixels.height * factor)
                let origin = CGPoint(x: (geometry.size.width - display.width) / 2, y: (geometry.size.height - display.height) / 2)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: NSImage(cgImage: thumbnail, size: .zero)).resizable().frame(width: display.width, height: display.height).position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    Rectangle().fill(Color.lime.opacity(0.12)).overlay(Rectangle().stroke(Color.lime, lineWidth: 2))
                        .frame(width: CGFloat(settings.width) * factor, height: CGFloat(settings.height) * factor)
                        .offset(x: origin.x + CGFloat(settings.x) * factor, y: origin.y + CGFloat(settings.y) * factor).allowsHitTesting(false)
                    if freehand {
                        Path { path in
                            if let first = settings.points.first { path.move(to: CGPoint(x: origin.x + first.x * factor, y: origin.y + first.y * factor)); for point in settings.points.dropFirst() { path.addLine(to: CGPoint(x: origin.x + point.x * factor, y: origin.y + point.y * factor)) } }
                        }.stroke(Color.lime, style: StrokeStyle(lineWidth: max(2, settings.lineWidth * factor), lineCap: .round, lineJoin: .round)).allowsHitTesting(false)
                    }
                    VStack { Spacer(); Text(freehand ? "Draw a path" : "Drag to select a rectangle").font(.system(size: 10)).padding(7).background(Color.paper.opacity(0.9)).clipShape(Capsule()).padding(10) }.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                }.contentShape(Rectangle()).clipped().gesture(DragGesture(minimumDistance: 3).onChanged { value in
                    func point(_ location: CGPoint) -> CGPoint { CGPoint(x: min(pixels.width, max(0, (location.x - origin.x) / factor)), y: min(pixels.height, max(0, (location.y - origin.y) / factor))) }
                    let start = point(value.startLocation), end = point(value.location)
                    if freehand {
                        if !drawing { settings.points = [ToolPoint(x: start.x, y: start.y)]; drawing = true }
                        if settings.points.count < 10_000 { settings.points.append(ToolPoint(x: end.x, y: end.y)) }
                        return
                    }
                    settings.x = Int(min(start.x, end.x)); settings.y = Int(min(start.y, end.y))
                    settings.width = max(1, Int(abs(end.x - start.x))); settings.height = max(1, Int(abs(end.y - start.y)))
                }.onEnded { _ in drawing = false })
            } else { FilePreview(url: url) }
        }.onAppear(perform: load).onChange(of: url) { _ in load() }
    }
    private func load() {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { thumbnail = nil; return }
        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? image.width
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? image.height
        let rotated = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        pixels = CGSize(width: rotated ? height : width, height: rotated ? width : height); thumbnail = image
    }
}

struct PDFPageOrganizer: View {
    let url: URL
    @Binding var settings: ToolSettings
    @State private var pages: [PageCard] = []
    @State private var document: PDFDocument?
    @State private var generatedOrder = ""
    @State private var generatedRotations = ""
    struct PageCard: Identifiable { let id = UUID(); var source: Int; var rotation: Int }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PAGES · CLICK CONTROLS TO ORGANIZE").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundColor(.muted)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, entry in
                    VStack(spacing: 6) {
                        if let page = document?.page(at: entry.source - 1) { Image(nsImage: page.thumbnail(of: NSSize(width: 80, height: 100), for: .mediaBox)).resizable().scaledToFit().frame(height: 90).rotationEffect(.degrees(Double(entry.rotation))) }
                        Text("\(index + 1) · source \(entry.source)").font(.system(size: 8, design: .monospaced))
                        HStack(spacing: 7) {
                            Button { if index > 0 { pages.swapAt(index, index - 1); sync() } } label: { Image(systemName: "arrow.left") }.disabled(index == 0).help("Move earlier")
                            Button { pages[index].rotation = (pages[index].rotation + 90) % 360; sync() } label: { Image(systemName: "rotate.right") }.help("Rotate this page")
                            Button { pages.insert(PageCard(source: entry.source, rotation: entry.rotation), at: index + 1); sync() } label: { Image(systemName: "plus.square.on.square") }.disabled(pages.count >= 1000).help("Duplicate this page")
                            Button { pages.remove(at: index); sync() } label: { Image(systemName: "trash") }.disabled(pages.count == 1).help("Remove this page")
                        }.buttonStyle(.borderless).font(.system(size: 9))
                    }.padding(8).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            Button("Reset to source order") { settings.pageOrder = ""; settings.pageRotations = ""; load() }.font(.system(size: 10))
            Text("Use page controls or the exact order below. Rotations apply to output positions, including independent duplicate pages.").font(.system(size: 10)).foregroundColor(.muted)
            Divider()
        }.onAppear(perform: load).onChange(of: url) { _ in load() }
            .onChange(of: settings.pageOrder) { value in if value != generatedOrder { load() } }
            .onChange(of: settings.pageRotations) { value in if value != generatedRotations { load() } }
    }
    private func sync() {
        generatedOrder = pages.map { String($0.source) }.joined(separator: ",")
        generatedRotations = pages.enumerated().filter { $0.element.rotation != 0 }.map { "\($0.offset + 1):\($0.element.rotation)" }.joined(separator: ",")
        settings.pageOrder = generatedOrder; settings.pageRotations = generatedRotations
    }
    private func load() {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0, doc.pageCount <= 1000 else { document = nil; pages = []; return }
        document = doc
        var order: [Int] = []
        if settings.pageOrder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { order = Array(1...doc.pageCount) }
        else {
            for token in settings.pageOrder.split(separator: ",") {
                let value = token.trimmingCharacters(in: .whitespaces)
                let bounds = value.split(separator: "-", omittingEmptySubsequences: false)
                if bounds.count == 2, let first = Int(bounds[0]), let last = Int(bounds[1]), (1...doc.pageCount).contains(first), (1...doc.pageCount).contains(last) { order += stride(from: first, through: last, by: first <= last ? 1 : -1) }
                else if let page = Int(value), (1...doc.pageCount).contains(page) { order.append(page) }
                else { return }
                if order.count > 1000 { return }
            }
        }
        var rotations: [Int: Int] = [:]
        for pair in settings.pageRotations.split(separator: ",") {
            let parts = pair.split(separator: ":")
            if parts.count == 2, let position = Int(parts[0].trimmingCharacters(in: .whitespaces)), let angle = Int(parts[1].trimmingCharacters(in: .whitespaces)), angle.isMultiple(of: 90) { rotations[position] = ((angle % 360) + 360) % 360 }
        }
        pages = order.enumerated().map { PageCard(source: $0.element, rotation: rotations[$0.offset + 1] ?? 0) }
        generatedOrder = settings.pageOrder; generatedRotations = settings.pageRotations
    }
}
