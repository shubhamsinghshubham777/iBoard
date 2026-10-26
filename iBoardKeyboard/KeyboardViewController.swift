import UIKit
import IBoardCore
import IBoardLayout
import IBoardTheme
import IBoardUI

/// Hosts the key grid (M1-03) and drives it through the touch state machine (M1-04).
final class KeyboardViewController: UIInputViewController {
    /// Settings read from the App Group on appear (works without Full Access).
    private(set) var settings = IBoardSettings.defaults

    private let grid = KeyGridView()
    private var heightConstraint: NSLayoutConstraint?
    private var layoutKind: LayoutKind = .letters
    private var lastLayoutKey: LayoutKey?
    private var perfDown: PerfInterval?
    private var perfUp: PerfInterval?
    private var machine: KeyboardInputMachine?
    private var layerChangePending = false
    private var repeatLink: CADisplayLink?
    private var hapticsEnabled: Bool { settings.haptics && hasFullAccess }

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
        grid.touchHandler = { [weak self] phase, id, point, time in self?.handleTouch(phase, id, point, time) }
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
        updateAutoShift()
    }

    /// Minimal auto-capitalisation on appear / external text changes (full input-layer rules come later).
    private func updateAutoShift() {
        guard machine != nil, layoutKind == .letters, machine!.shift != .capsLock else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        var want = ShiftState.off
        switch textDocumentProxy.autocapitalizationType ?? .none {
        case .allCharacters: want = .capsLock
        case .sentences: if before.isEmpty || before.hasSuffix("\n") { want = .once }
        case .words: if before.isEmpty || before.hasSuffix(" ") || before.hasSuffix("\n") { want = .once }
        default: break
        }
        machine!.setShift(want) { [grid] in if case .shiftChanged(let s) = $0 { grid.setShift(s) } }
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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        machine?.cancelAll { _ in }
        grid.clearHighlights()
        updateRepeatTimer()
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
        let layout = LayoutEngine.layout(containerSize: size, safeArea: safe, traits: traits, kind: layoutKind)
        grid.apply(layout: layout)
        if machine == nil {
            machine = KeyboardInputMachine(layout: layout)
            updateAutoShift()
        } else {
            machine!.setLayout(layout)
        }
    }

    // MARK: Touches -> state machine -> text proxy

    private func handleTouch(_ phase: KeyTouchPhase, _ id: Int, _ point: CGPoint, _ time: TimeInterval) {
        guard machine != nil else { return }
        let sink: (KeyEvent) -> Void = { [unowned self] in self.handle($0) }
        switch phase {
        case .began:
            perfDown = Perf.begin(.touchDownToHighlight)
            machine!.touchDown(id: id, at: point, time: time, emit: sink)
        case .moved:
            machine!.touchMoved(id: id, to: point, emit: sink)
        case .ended:
            perfUp = Perf.begin(.touchUpToInsert)
            machine!.touchUp(id: id, time: time, emit: sink)
            perfUp = nil // an up that inserts nothing is not a sample (the interval is closed in `handle`)
        case .cancelled:
            machine!.touchCancelled(id: id, emit: sink)
        }
        applyDeferredLayerChange()
        updateRepeatTimer()
    }

    /// Runs inside machine calls: must not touch `machine` (exclusive access).
    private func handle(_ event: KeyEvent) {
        switch event {
        case .highlight(let index, let on):
            grid.setHighlighted(index, on)
            if on, let p = perfDown { Perf.end(p); perfDown = nil }
        case .insert(let text):
            textDocumentProxy.insertText(text)
            feedback()
        case .deleteBackward:
            textDocumentProxy.deleteBackward()
            feedback()
        case .deleteWord:
            let n = max(wordDeleteCount(before: textDocumentProxy.documentContextBeforeInput ?? ""), 1)
            for _ in 0..<n { textDocumentProxy.deleteBackward() }
        case .returnKey:
            textDocumentProxy.insertText("\n")
            feedback()
        case .advanceKeyboard:
            advanceToNextInputMode()
        case .shiftChanged(let state):
            grid.setShift(state)
        case .layerChanged(let kind):
            layoutKind = kind
            layerChangePending = true
        }
        if let p = perfUp, !isHighlight(event) { Perf.end(p); perfUp = nil }
    }

    private func isHighlight(_ e: KeyEvent) -> Bool {
        if case .highlight = e { return true }
        return false
    }

    private func feedback() {
        // M1-05 owns click + haptics; until then only the existing opt-in haptic.
        if hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    private func applyDeferredLayerChange() {
        guard layerChangePending else { return }
        layerChangePending = false
        lastLayoutKey = nil
        relayoutIfNeeded()
        grid.clearHighlights()
    }

    // MARK: Delete repeat

    private func updateRepeatTimer() {
        if machine?.nextDeadline != nil {
            guard repeatLink == nil else { return }
            let link = CADisplayLink(target: RepeatTarget { [weak self] in self?.tickRepeat() }, selector: #selector(RepeatTarget.fire))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30)
            link.add(to: .main, forMode: .common)
            repeatLink = link
        } else {
            repeatLink?.invalidate()
            repeatLink = nil
        }
    }

    private func tickRepeat() {
        let sink: (KeyEvent) -> Void = { [unowned self] in self.handle($0) }
        machine?.tick(now: ProcessInfo.processInfo.systemUptime, emit: sink)
        updateRepeatTimer()
    }
}

private final class RepeatTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
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
