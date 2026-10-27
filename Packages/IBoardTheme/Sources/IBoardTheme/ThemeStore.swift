import Foundation

/// Where the app stores the chosen theme for the keyboard. The theme JSON lives in App Group defaults (the keyboard
/// reads app-written defaults without Full Access, P-23); pre-sized photos are files in the App Group container
/// (file reads without Full Access: NOT TESTED on device). Contains no typed text.
public struct ThemeStore: @unchecked Sendable {
    public static let appGroup = "group.app.iBoard"
    public static let selectedKey = "iboard.theme.selected"
    public static let userThemesKey = "iboard.theme.user"
    public static let maxUserThemes = 24

    private let defaults: UserDefaults?
    private let photoDirectory: URL?

    public init(suiteName: String? = ThemeStore.appGroup) {
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) }
        self.photoDirectory = suiteName.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)?.appendingPathComponent("ThemePhotos", isDirectory: true)
        }
    }

    public init(defaults: UserDefaults, photoDirectory: URL?) {
        self.defaults = defaults
        self.photoDirectory = photoDirectory
    }

    /// Selected theme; anything missing, oversized, newer or invalid yields the Native default (D-07).
    public func loadSelected() -> Theme {
        guard let data = defaults?.data(forKey: Self.selectedKey), let t = try? ThemeFile.import(data) else { return ThemePresets.native }
        return t
    }

    @discardableResult
    public func saveSelected(_ theme: Theme) -> Bool {
        guard let defaults, let data = try? ThemeFile.export(theme) else { return false }
        defaults.set(data, forKey: Self.selectedKey)
        return true
    }

    public func loadUserThemes() -> [Theme] {
        guard let blobs = defaults?.array(forKey: Self.userThemesKey) as? [Data] else { return [] }
        return blobs.compactMap { try? ThemeFile.import($0) }
    }

    @discardableResult
    public func saveUserThemes(_ themes: [Theme]) -> Bool {
        guard let defaults else { return false }
        let blobs = themes.prefix(Self.maxUserThemes).compactMap { try? ThemeFile.export($0) }
        defaults.set(blobs, forKey: Self.userThemesKey)
        return true
    }

    // MARK: Photos

    /// Writes both orientation JPEGs for `token` (a safe asset name). Returns false if the container is unavailable.
    @discardableResult
    public func savePhoto(token: String, portrait: Data, landscape: Data) -> Bool {
        guard ThemeFile.isSafeAssetName(token), let dir = photoDirectory else { return false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try portrait.write(to: dir.appendingPathComponent(PhotoPipeline.assetName(token: token, orientation: .portrait)), options: .atomic)
            try landscape.write(to: dir.appendingPathComponent(PhotoPipeline.assetName(token: token, orientation: .landscape)), options: .atomic)
            return true
        } catch { return false }
    }

    public func photoURL(token: String, orientation: PhotoOrientation) -> URL? {
        guard ThemeFile.isSafeAssetName(token) else { return nil }
        return photoDirectory?.appendingPathComponent(PhotoPipeline.assetName(token: token, orientation: orientation))
    }

    /// Removes photo files whose token is not referenced by any of `keep`.
    public func prunePhotos(keeping keep: [Theme]) {
        guard let dir = photoDirectory, let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        var tokens = Set<String>()
        for t in keep { for v in [t.light, t.dark] { if let a = v.backdrop.photoAsset { tokens.insert(a) } } }
        for f in files {
            let base = f.hasSuffix("-p.jpg") || f.hasSuffix("-l.jpg") ? String(f.dropLast(6)) : f
            if !tokens.contains(base) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        }
    }
}
