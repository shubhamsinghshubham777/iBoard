import CoreGraphics
import Foundation
import Testing
@testable import IBoardLayout

/// JSON snapshots of key frames per size and layout kind (Tests/IBoardLayoutTests/Snapshots/).
/// Regenerate after an intentional change:  IBOARD_UPDATE_SNAPSHOTS=1 swift test
struct SnapshotKey: Codable, Equatable {
    var id: String
    var row: Int
    var x, y, w, h: Double
    var rx, ry, rw, rh: Double   // touch region
}

struct LayoutSnapshot: Codable, Equatable {
    var width: Double
    var height: Double
    var kind: String
    var keys: [SnapshotKey]
}

struct SnapshotFile: Codable, Equatable {
    var name: String
    var layouts: [LayoutSnapshot]
}

private func r2(_ v: CGFloat) -> Double { (Double(v) * 100).rounded() / 100 }

func snapshot(of l: KeyboardLayout, label: String) -> LayoutSnapshot {
    LayoutSnapshot(
        width: r2(l.bounds.width), height: r2(l.bounds.height), kind: label,
        keys: l.keys.map {
            SnapshotKey(
                id: $0.identity.snapshotName, row: $0.row,
                x: r2($0.frame.minX), y: r2($0.frame.minY), w: r2($0.frame.width), h: r2($0.frame.height),
                rx: r2($0.touchRegion.minX), ry: r2($0.touchRegion.minY),
                rw: r2($0.touchRegion.width), rh: r2($0.touchRegion.height)
            )
        }
    )
}

private let snapshotDirectory: URL = {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent()
    return url.appendingPathComponent("Snapshots", isDirectory: true)
}()

private func verify(_ file: SnapshotFile) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let url = snapshotDirectory.appendingPathComponent("\(file.name).json")
    if ProcessInfo.processInfo.environment["IBOARD_UPDATE_SNAPSHOTS"] == "1" {
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url)
        return
    }
    guard let data = try? Data(contentsOf: url) else {
        Issue.record("Missing snapshot \(url.lastPathComponent); run with IBOARD_UPDATE_SNAPSHOTS=1")
        return
    }
    let expected = try JSONDecoder().decode(SnapshotFile.self, from: data)
    #expect(expected.layouts.count == file.layouts.count, "\(file.name): layout count changed")
    for (e, a) in zip(expected.layouts, file.layouts) {
        #expect(e == a, "\(file.name) / \(e.kind) differs from snapshot (regenerate with IBOARD_UPDATE_SNAPSHOTS=1)")
    }
}

@Suite("Snapshots")
struct SnapshotTests {
    @Test("every layout kind at every size", arguments: sizeCases)
    func sizes(sc: SizeCase) throws {
        let layouts = LayoutKind.allCases.map { snapshot(of: sc.layout($0), label: $0.rawValue) }
        try verify(SnapshotFile(name: sc.name, layouts: layouts))
    }

    @Test("trait variants at 390 pt portrait")
    func variants() throws {
        func make(_ label: String, _ kind: LayoutKind, _ t: LayoutTraits, _ s: LayoutSettings = LayoutSettings()) -> LayoutSnapshot {
            let h = LayoutEngine.preferredHeight(width: 390, traits: t, kind: kind, settings: s)
            return snapshot(
                of: LayoutEngine.layout(containerSize: CGSize(width: 390, height: h), traits: t, kind: kind, settings: s),
                label: label
            )
        }
        let layouts = [
            make("email", .letters, LayoutTraits(keyboardKind: .emailAddress)),
            make("url", .letters, LayoutTraits(keyboardKind: .url)),
            make("globe-letters", .letters, LayoutTraits(needsInputModeSwitchKey: true)),
            make("globe-numbers", .numbers, LayoutTraits(needsInputModeSwitchKey: true)),
            make("number-row", .letters, LayoutTraits(), LayoutSettings(numberRow: true)),
            make("punctuation-keys", .letters, LayoutTraits(), LayoutSettings(punctuationKeys: true)),
            make("return-send", .letters, LayoutTraits(returnKey: .send)),
            make("numbers-inr", .numbers, LayoutTraits(), LayoutSettings(currency: .inr)),
            make("height-1.4", .letters, LayoutTraits(), LayoutSettings(heightScale: 1.4)),
        ]
        try verify(SnapshotFile(name: "variants-w390", layouts: layouts))
    }
}
