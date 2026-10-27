import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import IBoardCore
import IBoardTheme

/// `.iboardtheme` document for fileExporter/fileImporter. The type is declared dynamically (conforming to JSON);
/// an exported UTType declaration is a follow-up in project.yml.
struct ThemeDocument: FileDocument {
    static let themeType = UTType(filenameExtension: ThemeFile.fileExtension, conformingTo: .json) ?? .json
    static var readableContentTypes: [UTType] { [themeType, .json] }
    static var writableContentTypes: [UTType] { [themeType] }
    var theme: Theme

    init(theme: Theme) { self.theme = theme }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ThemeError.malformed }
        theme = try ThemeFile.import(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try ThemeFile.export(theme))
    }
}

/// Theme studio state. Edits a working copy; "Use this theme" writes it to the App Group for the keyboard.
@MainActor @Observable
final class ThemeStudioModel {
    private let store = ThemeStore()
    var working: Theme
    var userThemes: [Theme]
    var appearance: ThemeAppearance = .light
    var previewPhoto: UIImage?
    var message: String?
    var isProcessingPhoto = false

    init() {
        working = store.loadSelected()
        userThemes = store.loadUserThemes()
    }

    var variant: ThemeVariant {
        get { working.variant(for: appearance) }
        set { if appearance == .light { working.light = newValue } else { working.dark = newValue } }
    }

    func choose(_ theme: Theme) { working = theme; previewPhoto = nil; message = nil }

    /// A preset that was edited becomes a user theme with its own id; presets are never overwritten.
    private func forkedIfNeeded() -> Theme {
        var t = working
        let isPreset = ThemePresets.all.contains { $0.id == t.id }
        if isPreset, !ThemePresets.all.contains(t) {
            t.id = UUID().uuidString
            t.name = "My \(t.name)"
        }
        return t
    }

    func apply() {
        let t = forkedIfNeeded()
        do {
            try ThemeFile.validate(t)
            working = t
            message = store.saveSelected(t) ? "Applied. The keyboard picks it up next time it opens." : "Could not save to the App Group."
            store.prunePhotos(keeping: [t] + userThemes)
        } catch { message = "This theme is not valid: \(error)" }
    }

    func saveToMyThemes() {
        var t = forkedIfNeeded()
        if ThemePresets.all.contains(where: { $0.id == t.id }) {
            t.id = UUID().uuidString
            t.name = "My \(t.name)"
        }
        if let i = userThemes.firstIndex(where: { $0.id == t.id }) { userThemes[i] = t } else { userThemes.append(t) }
        working = t
        store.saveUserThemes(userThemes)
        message = "Saved to My themes."
    }

    func delete(_ t: Theme) {
        userThemes.removeAll { $0.id == t.id }
        store.saveUserThemes(userThemes)
    }

    func importFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var t = try ThemeFile.import(Data(contentsOf: url))
            // Imported files never keep ids that could collide with presets or existing themes.
            t.id = UUID().uuidString
            // Photos are never embedded in a theme file, so an imported photo backdrop has nothing to show.
            for ap in [ThemeAppearance.light, .dark] {
                var v = t.variant(for: ap)
                if v.backdrop.kind == .photo { v.backdrop = .system; v.backdrop.photoAsset = nil }
                if ap == .light { t.light = v } else { t.dark = v }
            }
            working = t; previewPhoto = nil
            message = "Imported \(t.name). Review it, then use or save it."
        } catch let e as ThemeError {
            message = "Could not import: \(e)"
        } catch { message = "Could not read the file." }
    }

    /// Sizes below follow the keyboard's default heights scaled by the user's height setting, per orientation.
    func photoTargets(in scene: UIWindowScene?) -> (portrait: PhotoTarget, landscape: PhotoTarget) {
        let screen = scene?.screen
        let bounds = screen?.bounds.size ?? CGSize(width: 390, height: 844)
        let scale = Double(screen?.scale ?? 3)
        let s = SettingsStore().load()
        let pk = s.heightScale(forKey: HeightKey.make(displayClass: "phone", orientation: "portrait"))
        let lk = s.heightScale(forKey: HeightKey.make(displayClass: "phone", orientation: "landscape"))
        let narrow = Double(min(bounds.width, bounds.height)), wide = Double(max(bounds.width, bounds.height))
        return (.keyboard(widthPoints: narrow, heightPoints: 291 * pk, scale: scale),
                .keyboard(widthPoints: wide, heightPoints: 200 * lk, scale: scale))
    }

    func setPhoto(_ data: Data, scene: UIWindowScene?) async {
        isProcessingPhoto = true
        defer { isProcessingPhoto = false }
        let t = photoTargets(in: scene)
        let token = "photo-" + UUID().uuidString.prefix(8).lowercased()
        let store = self.store
        let result: Result<Data, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let p = try PhotoPipeline.process(data, target: t.portrait)
                let l = try PhotoPipeline.process(data, target: t.landscape)
                guard store.savePhoto(token: token, portrait: p, landscape: l) else { throw PhotoPipelineError.encodeFailed }
                return .success(p)
            } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let p):
            var v = variant
            v.backdrop = Backdrop(kind: .photo, photoAsset: token, blurRadius: 0)
            v.translucency = 1
            variant = v
            previewPhoto = UIImage(data: p)
            message = nil
        case .failure: message = "That image could not be used."
        }
    }
}

struct ThemeStudioView: View {
    @State private var model = ThemeStudioModel()
    @State private var photoItem: PhotosPickerItem?
    @State private var exporting = false
    @State private var importing = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            Section {
                ThemePreviewView(variant: model.variant, appearance: model.appearance, photo: model.previewPhoto)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                Picker("Editing", selection: $model.appearance) {
                    Text("Light").tag(ThemeAppearance.light)
                    Text("Dark").tag(ThemeAppearance.dark)
                }
                .pickerStyle(.segmented)
            } header: { Text("Live preview") } footer: {
                if model.variant.backdrop.kind == .systemMaterial {
                    Text("The real system glass is drawn by iOS inside the keyboard; the preview uses a stand-in.")
                }
            }

            Section("Presets") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(ThemePresets.all, id: \.id) { t in presetCell(t) }
                    }.padding(.vertical, 4)
                }
            }

            if !model.userThemes.isEmpty {
                Section("My themes") {
                    ForEach(model.userThemes, id: \.id) { t in
                        Button(t.name) { model.choose(t) }
                            .swipeActions { Button("Delete", role: .destructive) { model.delete(t) } }
                    }
                }
            }

            keysSection
            labelsSection
            backdropSection
            trailSection

            Section {
                Button("Use this theme") { model.apply() }.bold()
                Button("Save to My themes") { model.saveToMyThemes() }
                Button("Export .iboardtheme") { exporting = true }
                Button("Import .iboardtheme") { importing = true }
                Button("Reset to Native", role: .destructive) { model.choose(ThemePresets.native) }
                if let m = model.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Theme studio")
        .onAppear { model.appearance = scheme == .dark ? .dark : .light }
        .fileExporter(isPresented: $exporting, document: ThemeDocument(theme: model.working),
                      contentType: ThemeDocument.themeType, defaultFilename: model.working.name) { r in
            if case .failure = r { model.message = "Export failed." }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: ThemeDocument.readableContentTypes) { r in
            model.importFile(r.map { [$0] })
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                    await model.setPhoto(data, scene: scene)
                } else { model.message = "That image could not be loaded." }
                photoItem = nil
            }
        }
    }

    // MARK: Sections

    private var keysSection: some View {
        Section("Keys") {
            colorRow("Key fill", \.keys.fill)
            colorRow("Pressed fill", \.keys.pressedFill)
            colorRow("Action key fill", \.keys.actionFill)
            sliderRow("Opacity", \.keys.opacity, 0...1, format: .percent)
            sliderRow("Corner radius", \.keys.cornerRadius, 0...30)
            sliderRow("Border width", \.keys.borderWidth, 0...4)
            colorRow("Border colour", \.keys.borderColor)
            sliderRow("Shadow radius", \.keys.shadowRadius, 0...12)
            sliderRow("Shadow offset", \.keys.shadowOffsetY, -12...12)
            colorRow("Shadow colour", \.keys.shadowColor)
        }
    }

    private var labelsSection: some View {
        Section("Labels") {
            colorRow("Key labels", \.labels.key)
            colorRow("Action key labels", \.labels.actionKey)
            colorRow("Suggestion text", \.labels.strip)
            Picker("Weight", selection: bind(\.fonts.weight)) {
                ForEach(FontWeightToken.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
        }
    }

    private var backdropSection: some View {
        Section("Background") {
            Picker("Style", selection: Binding(
                get: { model.variant.backdrop.kind },
                set: { kind in
                    var v = model.variant
                    v.backdrop.kind = kind
                    if kind == .gradient, v.backdrop.gradient.count < 2 {
                        v.backdrop.gradient = [ThemeColor(hex: 0x3A4BD6), ThemeColor(hex: 0x0B0D1A)]
                    }
                    if kind == .solid, v.backdrop.solid.alpha == 0 { v.backdrop.solid = ThemeColor(hex: 0x1C1C1E) }
                    model.variant = v
                })) {
                Text("System").tag(BackdropKind.systemMaterial)
                Text("Colour").tag(BackdropKind.solid)
                Text("Gradient").tag(BackdropKind.gradient)
                Text("Photo").tag(BackdropKind.photo)
            }
            switch model.variant.backdrop.kind {
            case .systemMaterial:
                EmptyView()
            case .solid:
                colorRow("Colour", \.backdrop.solid)
                sliderRow("Translucency", \.translucency, 0...1, format: .percent)
            case .gradient:
                colorRow("From", gradientStop(0))
                colorRow("To", gradientStop(1))
                sliderRow("Angle", \.backdrop.gradientAngle, 0...360)
                sliderRow("Dim", \.dim, 0...0.8, format: .percent)
            case .photo:
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(model.isProcessingPhoto ? "Processing..." : "Choose photo", systemImage: "photo")
                }
                sliderRow("Blur", \.backdrop.blurRadius, 0...40)
                sliderRow("Dim", \.dim, 0...0.8, format: .percent)
                sliderRow("Translucency", \.translucency, 0...1, format: .percent)
                Text("The photo is resized on this device to the keyboard's exact pixel size and never leaves it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var trailSection: some View {
        Section("Swipe trail") {
            colorRow("Colour", \.swipeTrail.color)
            sliderRow("Width", \.swipeTrail.width, 1...16)
        }
    }

    // MARK: Cells and bindings

    private func presetCell(_ t: Theme) -> some View {
        Button { model.choose(t) } label: {
            VStack {
                ThemePreviewView(variant: t.variant(for: model.appearance), appearance: model.appearance)
                    .frame(width: 150).scaleEffect(0.5, anchor: .topLeading).frame(width: 75, height: 80, alignment: .topLeading)
                    .clipped()
                Text(t.name).font(.caption)
            }
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.working.id == t.id ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.name)
    }

    private func bind<V>(_ kp: WritableKeyPath<ThemeVariant, V>) -> Binding<V> {
        Binding(get: { model.variant[keyPath: kp] }, set: { model.variant[keyPath: kp] = $0 })
    }

    private func gradientStop(_ i: Int) -> WritableKeyPath<ThemeVariant, ThemeColor> {
        i == 0 ? \.backdrop.gradient[0] : \.backdrop.gradient[1]
    }

    private func colorRow(_ title: String, _ kp: WritableKeyPath<ThemeVariant, ThemeColor>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { model.variant[keyPath: kp].swiftUI },
            set: { model.variant[keyPath: kp] = ThemeColor($0) }
        ), supportsOpacity: true)
    }

    private func sliderRow(_ title: String, _ kp: WritableKeyPath<ThemeVariant, Double>, _ range: ClosedRange<Double>,
                           format: SliderFormat = .number) -> some View {
        let value = model.variant[keyPath: kp]
        return VStack(alignment: .leading) {
            Text("\(title): \(format == .percent ? "\(Int((value * 100).rounded())) %" : String(format: "%.1f", value))")
            Slider(value: Binding(get: { value }, set: { model.variant[keyPath: kp] = min(max($0, range.lowerBound), range.upperBound) }),
                   in: range)
        }
    }

    enum SliderFormat { case number, percent }
}

#Preview { NavigationStack { ThemeStudioView() } }
