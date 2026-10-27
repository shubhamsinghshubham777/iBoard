import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import IBoardTheme

struct PhotoPipelineTests {
    /// Generated test image: left half red, right half blue, as PNG.
    private func makeImage(_ w: Int, _ h: Int) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
        let d = NSMutableData()
        let dest = CGImageDestinationCreateWithData(d, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return d as Data
    }

    @Test func outputsExactTargetSizeForBothOrientations() throws {
        let src = makeImage(2000, 1500)
        for t in [PhotoTarget(pixelWidth: 1170, pixelHeight: 840), PhotoTarget(pixelWidth: 2400, pixelHeight: 600)] {
            let out = try PhotoPipeline.process(src, target: t)
            let s = try #require(PhotoPipeline.pixelSize(of: out))
            #expect(s.width == t.pixelWidth && s.height == t.pixelHeight)
        }
    }

    @Test func smallSourceIsUpscaledToExactSize() throws {
        let out = try PhotoPipeline.process(makeImage(100, 400), target: PhotoTarget(pixelWidth: 300, pixelHeight: 100))
        let s = try #require(PhotoPipeline.pixelSize(of: out))
        #expect(s.width == 300 && s.height == 100)
    }

    @Test func keepsColoursAfterCrop() throws {
        let out = try PhotoPipeline.process(makeImage(800, 800), target: PhotoTarget(pixelWidth: 200, pixelHeight: 100))
        let src = CGImageSourceCreateWithData(out as CFData, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        var px = [UInt8](repeating: 0, count: 4 * 200 * 100)
        let ctx = CGContext(data: &px, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(px[(50 * 200 + 20) * 4] > 200 && px[(50 * 200 + 20) * 4 + 2] < 60)      // left red
        #expect(px[(50 * 200 + 180) * 4 + 2] > 200 && px[(50 * 200 + 180) * 4] < 60)    // right blue
    }

    @Test func rejectsBadInput() {
        #expect(throws: PhotoPipelineError.unreadableImage) { try PhotoPipeline.process(Data("nope".utf8), target: .init(pixelWidth: 10, pixelHeight: 10)) }
        #expect(throws: PhotoPipelineError.invalidTarget) { try PhotoPipeline.process(makeImage(10, 10), target: .init(pixelWidth: 0, pixelHeight: 10)) }
    }

    @Test func targetFromPointsAndScale() {
        #expect(PhotoTarget.keyboard(widthPoints: 390, heightPoints: 291, scale: 3) == PhotoTarget(pixelWidth: 1170, pixelHeight: 873))
    }

    @Test func storeSelectedAndPhotosRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThemeStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!, photoDirectory: dir)
        #expect(store.loadSelected() == ThemePresets.native)
        var t = ThemePresets.midnight
        t.light.backdrop = Backdrop(kind: .photo, photoAsset: "pic1", blurRadius: 8)
        #expect(store.saveSelected(t))
        // Colours quantise to 8 bits on save, so compare canonical exports.
        #expect(try ThemeFile.export(store.loadSelected()) == ThemeFile.export(t))
        #expect(store.savePhoto(token: "pic1", portrait: Data([1]), landscape: Data([2])))
        #expect(store.savePhoto(token: "../x", portrait: Data(), landscape: Data()) == false)
        #expect(FileManager.default.fileExists(atPath: try #require(store.photoURL(token: "pic1", orientation: .landscape)).path))
        _ = store.savePhoto(token: "old", portrait: Data([1]), landscape: Data([1]))
        store.prunePhotos(keeping: [t])
        #expect(!FileManager.default.fileExists(atPath: try #require(store.photoURL(token: "old", orientation: .portrait)).path))
        #expect(FileManager.default.fileExists(atPath: try #require(store.photoURL(token: "pic1", orientation: .portrait)).path))
        #expect(store.saveUserThemes([t]))
        #expect(try store.loadUserThemes().map { try ThemeFile.export($0) } == [ThemeFile.export(t)])
    }
}
