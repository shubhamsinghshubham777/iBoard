import UIKit
import IBoardCore
import IBoardLayout
import IBoardTheme
import IBoardUI

/// Hosts the key grid (M1-03). Typing is not wired yet (M1-04): touches only highlight the key under the finger.
final class KeyboardViewController: UIInputViewController {
    /// Settings read from the App Group on appear (works without Full Access).
    private(set) var settings = IBoardSettings.defaults

    private let grid = KeyGridView()
    private var heightConstraint: NSLayoutConstraint?
    private var layoutKind: LayoutKind = .letters
    private var lastLayoutKey: LayoutKey?
    private var perfDown: PerfInterval?

    /// What the current layout was computed from; used to skip redundant relayouts.
    private struct LayoutKey: Equatable {
        var size: CGSize
        var safe: LayoutInsets
        var traits: LayoutTraits
        var kind: LayoutKind
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        settings = SettingsStore().load()
        refreshAppearanceAndTraits()
        #if DEBUG
        // Debug-only exposure for UI tests / inspection: no typed text involved.
        grid.accessibilityValue = "haptics=\(settings.haptics) fullAccess=\(hasFullAccess)"
        #endif
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear // P-22: the system draws the keyboard backdrop
        grid.frame = view.bounds
        grid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        grid.accessibilityIdentifier = "key-grid"
        grid.touchHandler = { [weak self] phase, id, point, _ in self?.handleTouch(phase, point) }
        view.addSubview(grid)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: KeyboardViewController, _) in
            self.refreshAppearanceAndTraits()
        }

        let h = view.heightAnchor.constraint(equalToConstant: 260)
        h.priority = .required - 1
        h.isActive = true
        heightConstraint = h
        #if DEBUG
        DebugOverlayView.install(in: view)
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        relayoutIfNeeded()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        refreshAppearanceAndTraits()
    }

    // MARK: Layout

    private func currentTraits() -> LayoutTraits {
        let proxy = textDocumentProxy
        return LayoutTraits(
            displayClass: .phone,
            orientation: view.bounds.width > view.bounds.height ? .landscape : .portrait,
            keyboardKind: KeyboardKind(proxy.keyboardType ?? .default),
            returnKey: ReturnKeyKind(proxy.returnKeyType ?? .default),
            needsInputModeSwitchKey: needsInputModeSwitchKey
        )
    }

    private func refreshAppearanceAndTraits() {
        switch textDocumentProxy.keyboardAppearance ?? .default {
        case .dark: grid.appearance = .dark
        case .light: grid.appearance = .light
        default: grid.appearance = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
        relayoutIfNeeded()
    }

    private func relayoutIfNeeded() {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let safe = LayoutInsets(
            top: 0, left: view.safeAreaInsets.left, bottom: view.safeAreaInsets.bottom, right: view.safeAreaInsets.right
        )
        let traits = currentTraits()
        let key = LayoutKey(size: size, safe: safe, traits: traits, kind: layoutKind)
        guard key != lastLayoutKey else { return }
        lastLayoutKey = key

        let want = LayoutEngine.preferredHeight(width: size.width, safeArea: safe, traits: traits, kind: layoutKind)
        if abs((heightConstraint?.constant ?? 0) - want) > 0.5 { heightConstraint?.constant = want }
        grid.apply(layout: LayoutEngine.layout(containerSize: size, safeArea: safe, traits: traits, kind: layoutKind))
    }

    // MARK: Touches (interim: highlight only, replaced by the state machine in M1-04)

    private var highlightedKey = -1

    private func handleTouch(_ phase: KeyTouchPhase, _ point: CGPoint) {
        switch phase {
        case .began, .moved:
            if phase == .began { perfDown = Perf.begin(.touchDownToHighlight) }
            let index = grid.layout?.nearestHit(to: point)?.keyIndex ?? -1
            if index != highlightedKey {
                grid.setHighlighted(highlightedKey, false)
                grid.setHighlighted(index, true)
                highlightedKey = index
            }
            if let p = perfDown { Perf.end(p); perfDown = nil }
        case .ended, .cancelled:
            grid.setHighlighted(highlightedKey, false)
            highlightedKey = -1
        }
    }
}

// MARK: - UIKit -> layout value mapping

extension KeyboardKind {
    init(_ type: UIKeyboardType) {
        switch type {
        case .asciiCapable: self = .asciiCapable
        case .numbersAndPunctuation: self = .numbersAndPunctuation
        case .URL: self = .url
        case .numberPad: self = .numberPad
        case .phonePad: self = .phonePad
        case .namePhonePad: self = .namePhonePad
        case .emailAddress: self = .emailAddress
        case .decimalPad: self = .decimalPad
        case .twitter: self = .twitter
        case .webSearch: self = .webSearch
        case .asciiCapableNumberPad: self = .asciiCapableNumberPad
        default: self = .default
        }
    }
}

extension ReturnKeyKind {
    init(_ type: UIReturnKeyType) {
        switch type {
        case .go: self = .go
        case .google: self = .google
        case .join: self = .join
        case .next: self = .next
        case .route: self = .route
        case .search: self = .search
        case .send: self = .send
        case .yahoo: self = .yahoo
        case .done: self = .done
        case .emergencyCall: self = .emergencyCall
        case .continue: self = .continue
        default: self = .default
        }
    }
}
