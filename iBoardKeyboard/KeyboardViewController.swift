import UIKit
import IBoardCore

/// M0-02 stub: one "a" key proving the extension loads and can type. Replaced by the real grid in M1.
final class KeyboardViewController: UIInputViewController {
    /// Settings read from the App Group on appear (works without Full Access).
    private(set) var settings = IBoardSettings.defaults
    private weak var keyButton: UIButton?
    /// Haptics only fire with Full Access.
    private var hapticsEnabled: Bool { settings.haptics && hasFullAccess }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        settings = SettingsStore().load()
        #if DEBUG
        // Debug-only exposure for UI tests / inspection: no typed text involved.
        keyButton?.accessibilityValue = "haptics=\(settings.haptics) fullAccess=\(hasFullAccess)"
        #endif
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let key = UIButton(type: .system)
        key.setTitle("a", for: .normal)
        key.titleLabel?.font = .systemFont(ofSize: 24)
        key.accessibilityIdentifier = "key-a"
        key.translatesAutoresizingMaskIntoConstraints = false
        key.addAction(UIAction { [weak self] _ in
            let t = Perf.begin(.touchUpToInsert)
            self?.textDocumentProxy.insertText("a")
            if self?.hapticsEnabled == true { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            Perf.end(t)
        }, for: .touchUpInside)
        keyButton = key
        view.addSubview(key)
        NSLayoutConstraint.activate([
            key.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            key.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            key.widthAnchor.constraint(equalToConstant: 80),
            key.heightAnchor.constraint(equalToConstant: 48),
            view.heightAnchor.constraint(equalToConstant: 216),
        ])
        #if DEBUG
        DebugOverlayView.install(in: view)
        #endif
    }
}
