#if canImport(UIKit)
import UIKit
import CoreImage
import ImageIO
import IBoardLayout
import IBoardTheme

/// The themed backdrop behind keys and strip (F10): solid colour, gradient, or the pre-sized photo the app wrote.
/// `systemMaterial` draws nothing at all (P-22: iOS paints the keyboard glass; no effect views here, D-08 of M0-04).
///
/// Cost model: one layer per ingredient, never per key. A photo is decoded once at the size the app stored (it never
/// decodes anything larger than it draws, P-21), blurred once off the main thread (re-done only when the theme, orientation or
/// scale changes); a missing or unreadable file hides the backdrop so the keyboard falls back to the system look.
@MainActor
public final class ThemeBackdropView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let imageLayer = CALayer()
    private let dimLayer = CALayer()
    private var photoKey: String?
    private var loadTask: Task<Void, Never>?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        dimLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        for l in [gradientLayer, imageLayer, dimLayer] {
            l.actions = ["contents": NSNull(), "opacity": NSNull(), "colors": NSNull(), "frame": NSNull(), "bounds": NSNull(),
                         "position": NSNull(), "hidden": NSNull(), "startPoint": NSNull(), "endPoint": NSNull()]
            l.isHidden = true
            layer.addSublayer(l)
        }
        accessibilityIdentifier = "theme-backdrop"
    }

    public required init?(coder: NSCoder) { fatalError("unused") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [gradientLayer, imageLayer, dimLayer] { l.frame = bounds }
        CATransaction.commit()
    }

    /// Installs `spec`. `photoURL` is the stored file for the current orientation (nil when there is none).
    public func apply(_ spec: BackdropSpec, photoURL: URL?, displayScale: CGFloat) {
        loadTask?.cancel()
        loadTask = nil
        photoKey = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        gradientLayer.isHidden = true
        imageLayer.isHidden = true
        imageLayer.contents = nil
        dimLayer.isHidden = true
        backgroundColor = nil
        guard spec.drawsAnything else { isHidden = true; return }
        alpha = CGFloat(spec.opacity)
        dimLayer.opacity = Float(spec.dim)
        switch spec.kind {
        case .systemMaterial:
            isHidden = true
        case .solid:
            isHidden = false
            backgroundColor = UIColor(cgColor: spec.solid.cgColor)
        case .gradient:
            isHidden = false
            let stops = spec.gradient.map(\.cgColor)
            gradientLayer.colors = stops.count >= 2 ? stops : nil
            let p = spec.gradientPoints
            gradientLayer.startPoint = p.start
            gradientLayer.endPoint = p.end
            gradientLayer.isHidden = stops.count < 2
            dimLayer.isHidden = spec.dim <= 0
            isHidden = stops.count < 2
        case .photo:
            // Hidden until the file decoded: a missing file shows the system look, never a blank panel.
            isHidden = true
            guard let url = photoURL, FileManager.default.isReadableFile(atPath: url.path) else { return }
            let key = "\(url.lastPathComponent)|\(spec.blurRadius)|\(displayScale)"
            photoKey = key
            let blur = spec.blurRadius, dim = spec.dim
            loadTask = Task { [weak self] in
                let image = await Task.detached(priority: .userInitiated) {
                    Self.decode(url: url, blurPoints: blur, scale: displayScale)
                }.value
                guard !Task.isCancelled, let self, self.photoKey == key, let image else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.imageLayer.contents = image
                self.imageLayer.isHidden = false
                self.dimLayer.isHidden = dim <= 0
                self.isHidden = false
                CATransaction.commit()
            }
        }
    }

    /// Decodes the pre-sized JPEG (ImageIO, no caching) and blurs it once. Runs off the main thread.
    nonisolated static func decode(url: URL, blurPoints: Double, scale: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        guard blurPoints > 0 else { return img }
        // A blurred backdrop needs no full resolution: work at half size (a quarter of the pixels in memory), the layer
        // scales it back up when drawing.
        let input = CIImage(cgImage: img).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        let sigma = blurPoints * Double(scale) / 4
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(blurred, from: input.extent) ?? img
    }
}
#endif
