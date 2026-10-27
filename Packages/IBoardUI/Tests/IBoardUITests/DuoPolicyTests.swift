import CoreGraphics
import Foundation
import Testing
import IBoardLayout
@testable import IBoardUI

@Suite("Duo policy")
struct DuoPolicyTests {
    @Test func displayClassFromScreenMetrics() {
        #expect(DisplayMetrics.displayClass(screenSize: CGSize(width: 390, height: 844)) == .phone)   // iPhone 12 class
        #expect(DisplayMetrics.displayClass(screenSize: CGSize(width: 440, height: 956)) == .phone)   // widest phone
        #expect(DisplayMetrics.displayClass(screenSize: CGSize(width: 466, height: 678)) == .duoOuter)
        #expect(DisplayMetrics.displayClass(screenSize: CGSize(width: 678, height: 466)) == .duoOuter) // landscape
        #expect(DisplayMetrics.displayClass(screenSize: CGSize(width: 669, height: 951)) == .duoInner)
        #expect(DisplayMetrics.displayClass(screenSize: CGSize(width: 951, height: 669)) == .duoInner)
        #expect(DisplayMetrics.displayClass(screenSize: .zero) == .phone)
    }

    @Test func orientationFromScreenShape() {
        #expect(DisplayMetrics.orientation(screenSize: CGSize(width: 669, height: 951)) == .portrait)
        #expect(DisplayMetrics.orientation(screenSize: CGSize(width: 951, height: 669)) == .landscape)
    }

    @Test func splitResolutionOrder() {
        #expect(DuoSplitPolicy.resolve(local: false, app: true, fallback: true) == false)
        #expect(DuoSplitPolicy.resolve(local: nil, app: false, fallback: true) == false)
        #expect(DuoSplitPolicy.resolve(local: nil, app: nil, fallback: true))
    }

    @Test func explicitAppValueNeedsTheKeyInTheBlob() {
        let blob = Data(#"{"version":3,"duoSplitLandscape":false}"#.utf8)
        #expect(DuoSplitPolicy.explicitAppValue(blob: blob, key: "duoSplitLandscape") == false)
        #expect(DuoSplitPolicy.explicitAppValue(blob: blob, key: "duoSplitPortrait") == nil)
        #expect(DuoSplitPolicy.explicitAppValue(blob: nil, key: "duoSplitLandscape") == nil)
        #expect(DuoSplitPolicy.explicitAppValue(blob: Data("x".utf8), key: "k") == nil)
    }

    @Test func pinchDecision() {
        #expect(DuoSplitPolicy.decision(forPinchScale: 1.4) == true)
        #expect(DuoSplitPolicy.decision(forPinchScale: 0.6) == false)
        #expect(DuoSplitPolicy.decision(forPinchScale: 1.0) == nil)
    }

    @Test func localStoreRemembersPerOrientation() {
        let d = UserDefaults(suiteName: "duo-policy-test-\(UUID().uuidString)")!
        let s = DuoLocalStore(defaults: d)
        #expect(s.split(for: .landscape) == nil)
        s.setSplit(false, for: .landscape)
        s.setSplit(true, for: .portrait)
        #expect(s.split(for: .landscape) == false)
        #expect(s.split(for: .portrait) == true)
        #expect(s.fillToFold == false)
        s.setFillToFold(true)
        #expect(s.fillToFold)
    }

    /// The layout the host builds for the inner landscape default: no key cap or strip run touches the fold band.
    @Test func innerLandscapeDefaultSplitKeepsTheFoldClear() {
        let traits = LayoutTraits(displayClass: .duoInner, orientation: .landscape)
        let settings = LayoutSettings.defaults(for: traits)
        let l = LayoutEngine.layout(containerSize: CGSize(width: 951, height: 334), safeArea: LayoutInsets(top: 0, left: 0, bottom: 21, right: 0),
                                    traits: traits, kind: .letters, settings: settings)
        let band = try! #require(l.foldBand)
        #expect(l.stripSegments.count == 2)
        for k in l.keys { #expect(!k.frame.intersects(band)) }
        for s in l.stripSegments { #expect(!s.intersects(band)) }
    }
}
