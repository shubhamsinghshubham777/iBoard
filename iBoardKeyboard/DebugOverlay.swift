#if DEBUG
import UIKit
import IBoardCore

/// DEBUG-only perf overlay (M0-13). Shows live memory footprint and p50/p95 per metric.
/// Toggle: long-press the hidden top-right corner area, or set UserDefaults `iBoard.debugOverlay` = true.
/// Displays numbers only; never any typed text.
final class DebugOverlayView: UIView {
    static let defaultsKey = "iBoard.debugOverlay"

    private let label = UILabel()
    private var timer: Timer?

    /// Installs the hidden toggle area and the overlay into `host`.
    static func install(in host: UIView) {
        let overlay = DebugOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(overlay)

        let hotspot = UIView()
        hotspot.translatesAutoresizingMaskIntoConstraints = false
        hotspot.backgroundColor = .clear
        hotspot.addGestureRecognizer(UILongPressGestureRecognizer(target: overlay, action: #selector(toggle(_:))))
        host.addSubview(hotspot)

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: host.topAnchor, constant: 4),
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 4),
            hotspot.topAnchor.constraint(equalTo: host.topAnchor),
            hotspot.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            hotspot.widthAnchor.constraint(equalToConstant: 44),
            hotspot.heightAnchor.constraint(equalToConstant: 44),
        ])
        overlay.setVisible(UserDefaults.standard.bool(forKey: defaultsKey))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.7)
        layer.cornerRadius = 6
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        label.textColor = .green
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func toggle(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let show = isHidden
        UserDefaults.standard.set(show, forKey: Self.defaultsKey)
        setVisible(show)
    }

    private func setVisible(_ show: Bool) {
        isHidden = !show
        timer?.invalidate()
        timer = nil
        guard show else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            MainActor.assumeIsolated { self.refresh() }
        }
    }

    private func refresh() {
        var lines = [String(format: "mem %.1f MB", Perf.memoryFootprintMB())]
        for s in Perf.summaries() where s.count > 0 {
            lines.append(String(format: "%@ p50 %.1f p95 %.1f ms (n%d)", s.metric.label,
                                s.p50Milliseconds ?? 0, s.p95Milliseconds ?? 0, s.count))
        }
        label.text = lines.joined(separator: "\n")
    }
}
#endif
