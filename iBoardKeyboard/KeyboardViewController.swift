import UIKit
import IBoardCore
import IBoardEngine
import IBoardLayout
import IBoardTheme
import IBoardUI

/// Hosts the key grid (M1-03) and drives it through the touch state machine (M1-04).
final class KeyboardViewController: UIInputViewController {
    /// Settings read from the App Group on appear (works without Full Access).
    private(set) var settings = IBoardSettings.defaults

    private let grid = KeyGridView()
    private let strip = SuggestionStripView()
    private let handle = ResizeHandleView()
    private let overrides = LocalLayoutOverrides()
    /// Scale while the handle is being dragged (not persisted until the drag ends).
    private var liveScale: Double?
    private var dragStartHeight: CGFloat = 0
    private var consumeShiftOnce = false
    private var heightConstraint: NSLayoutConstraint?
    private var layoutKind: LayoutKind = .letters
    private var lastLayoutKey: LayoutKey?
    private var perfDown: PerfInterval?
    private var perfUp: PerfInterval?
    private var machine: KeyboardInputMachine?
    private var layerChangePending = false
    private var repeatLink: CADisplayLink?
    private var hapticsEnabled: Bool { settings.haptics && hasFullAccess }
    private lazy var input = InputController(proxy: ProxyAdapter(controller: self))
    private var haptic: UIImpactFeedbackGenerator?
    private var autoShiftPending = false
    private lazy var coordinator = TypingCoordinator(input: input)
    private var engineLoadStarted = false
    /// The loaded engine / personal store / command applier, nil until the background load finished.
    private var host: EngineHost.Loaded?
    /// Typing insight counters (F16): aggregate counts only, kept extension-locally; shared with the app only with
    /// Full Access (P-23).
    private lazy var insights: InsightRecorder = {
        let r = InsightRecorder(counters: EngineHost.Insights.loadLocal())
        r.persist = { [weak self] c in EngineHost.Insights.save(c, hasFullAccess: self?.hasFullAccess ?? false) }
        return r
    }()
    private var sharedSnapshotDirty = false
    private var lastDocumentID: UUID?
    private var stripTouchID: Int?
    /// Swipe typing capture (M4-01): one finger at a time; trail drawn by `grid.trail`.
    private var swipeCapture = SwipeCapture()
    /// Keyboard-local placeholder for the incognito toggle (F15 UI comes later). Never leaves the extension.
    static let incognitoKey = "iBoard.incognito"
    #if DEBUG
    private var engineStatus = "engine: loading"
    private weak var debugOverlay: DebugOverlayView?
    #endif

    /// What the current layout was computed from; used to skip redundant relayouts.
    private struct LayoutKey: Equatable {
        var size: CGSize
        var safe: LayoutInsets
        var traits: LayoutTraits
        var kind: LayoutKind
        var layoutSettings: LayoutSettings
    }

    /// P-23: `playInputClick` only sounds when the input view adopts `UIInputViewAudioFeedback`.
    override func loadView() {
        inputView = ClickInputView(frame: .zero, inputViewStyle: .keyboard)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        settings = SettingsStore().load()
        refreshAppearanceAndTraits()
        coordinator.setIncognito(UserDefaults.standard.bool(forKey: Self.incognitoKey))
        applyFieldConfig(forceFieldChange: true)
        applyAppCommands()
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
        handle.onDragBegan = { [weak self] in self?.dragStartHeight = self?.view.bounds.height ?? 0 }
        handle.onDragChanged = { [weak self] dy in self?.dragHandle(translationY: dy) }
        handle.onDragEnded = { [weak self] in self?.endDrag() }
        handle.onDoubleTap = { [weak self] in self?.toggleNumberRow() }
        view.addSubview(handle)
        view.addSubview(strip) // above the grid; not interactive, so touches still reach the grid
        coordinator.shiftActive = { [weak self] in (self?.grid.shift ?? .off) != .off } // not `machine`: this runs inside machine calls
        coordinator.onAsyncEdit = { [weak self] in self?.scheduleAutoShift() }
        coordinator.onInsight = { [weak self] event in
            self?.insights.handle(event)
            self?.sharedSnapshotDirty = true
        }
        coordinator.onStripChange = { [weak self] content in self?.strip.slotTexts = content.texts }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitVerticalSizeClass.self]) { (self: KeyboardViewController, _) in
            self.refreshAppearanceAndTraits()
        }

        let h = view.heightAnchor.constraint(equalToConstant: 260)
        h.priority = .required - 1
        h.isActive = true
        heightConstraint = h
        #if DEBUG
        debugOverlay = DebugOverlayView.install(in: view)
        debugOverlay?.onToggleIncognito = { [weak self] in self?.toggleIncognito() }
        debugOverlay?.refreshHook = { [weak self] in self?.refreshDebugStatus() }
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        relayoutIfNeeded()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        refreshAppearanceAndTraits()
        applyFieldConfig(forceFieldChange: false)
        updateAutoShift()
        // The proxy settles a run-loop turn after the host's edit.
        DispatchQueue.main.async { [weak self] in self?.coordinator.resync() }
    }

    /// Applies field traits (autocapitalisation, auto-enabled return key) and the shift state they imply.
    /// Reads the left context transiently; nothing is stored.
    private func updateAutoShift() {
        let proxy = textDocumentProxy
        input.traits = InputFieldTraits(
            autoCap: AutoCapMode(proxy.autocapitalizationType ?? .none),
            enablesReturnKeyAutomatically: proxy.enablesReturnKeyAutomatically ?? false
        )
        grid.setReturnKeyEnabled(input.isReturnKeyEnabled)
        guard machine != nil, layoutKind == .letters else { return }
        // Manual caps lock stays unless the field forces all caps / the field changed to a mode without it.
        if machine!.shift == .capsLock && input.traits.autoCap != .allCharacters { return }
        machine!.setShift(coordinator.autoShift(context: textDocumentProxy.documentContextBeforeInput)) {
            [grid] in if case .shiftChanged(let s) = $0 { grid.setShift(s) }
        }
    }

    /// Maps the field's UIKit traits into the engine's value types and tells the coordinator (F2 traits, F4 exclusions).
    private func applyFieldConfig(forceFieldChange: Bool) {
        let proxy = textDocumentProxy
        func sw(_ v: Int?) -> TraitSwitch { v == 1 ? .no : (v == 2 ? .yes : .default) } // UITextAutocorrectionType etc.
        let kind = FieldKeyboardKind(uikitRawValue: proxy.keyboardType?.rawValue ?? 0)
        let learning = FieldTraits(
            contentType: FieldContentType(rawValue: proxy.textContentType?.rawValue),
            keyboardType: kind,
            isSecureTextEntry: proxy.isSecureTextEntry ?? false
        )
        let excluded = learning.exclusion != nil
        var punct = PunctuationTraits(
            autocapitalization: {
                switch proxy.autocapitalizationType ?? .none {
                case .words: .words
                case .sentences: .sentences
                case .allCharacters: .allCharacters
                default: .none
                }
            }(),
            smartQuotes: sw(proxy.smartQuotesType?.rawValue),
            smartDashes: sw(proxy.smartDashesType?.rawValue),
            doubleSpacePeriod: !excluded
        )
        if excluded { punct.smartQuotes = .no; punct.smartDashes = .no }
        let config = FieldConfig(
            learning: learning,
            autocorrect: AutocorrectTraits(autocorrection: sw(proxy.autocorrectionType?.rawValue),
                                           spellChecking: sw(proxy.spellCheckingType?.rawValue)),
            punctuation: punct
        )
        let doc = proxy.documentIdentifier
        if forceFieldChange || doc != lastDocumentID {
            lastDocumentID = doc
            coordinator.fieldDidChange(config)
        } else {
            coordinator.updateConfig(config)
        }
    }

    private func toggleIncognito() {
        let on = !UserDefaults.standard.bool(forKey: Self.incognitoKey)
        UserDefaults.standard.set(on, forKey: Self.incognitoKey)
        coordinator.setIncognito(on)
    }

    /// Starts the background engine + personal learner load once, with the first letters layout.
    private func startEngineLoad(layout: KeyboardLayout) {
        guard !engineLoadStarted, layout.kind == .letters else { return }
        engineLoadStarted = true
        let fullAccess = hasFullAccess
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = await EngineHost.load(layout: layout, hasFullAccess: fullAccess)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.host = loaded
                self.coordinator.setEngine(loaded.engine)
                self.coordinator.setSwipeDecoder(loaded.swipe)
                self.coordinator.setLearner(loaded.learner)
                self.coordinator.setTouchModel(loaded.touchModel, store: loaded.touchStore)
                self.applyAppCommands()
                #if DEBUG
                self.engineStatus = loaded.engine == nil
                    ? "engine: none (stub)" : "engine: bundled \(loaded.wordCount) words"
                self.personalStore = loaded.learner
                self.personalMode = loaded.storageMode == .appGroup ? "app-group" : "local"
                #endif
            }
        }
    }

    /// Applies commands the app queued (docs/APP_COMMANDS.md) once per appearance, never per keystroke. Without
    /// Full Access the queue is still readable (P-23) and everything happens extension-locally.
    private func applyAppCommands() {
        guard let host else { return } // runs again right after the load finishes
        Task { [weak self] in
            let report = await host.commands.applyPending()
            guard let self else { return }
            if report.resetInsights { self.insights.reset(at: Date().timeIntervalSince1970) }
            if report.clearedPersonalData { self.coordinator.resetTouchModel() }
            if report.applied > 0 {
                await host.engine?.refreshPersonal()
                self.sharedSnapshotDirty = true
                if self.hasFullAccess { await EngineHost.writeSharedSnapshot(store: host.store) }
            }
        }
    }

    /// Keyboard hidden: close the typing session, learn the last words, and (Full Access) refresh the app's snapshot.
    private func settleOnDisappear() {
        insights.endSession()
        coordinator.flushLearner()
        guard let host else { return }
        let shareSnapshot = hasFullAccess && sharedSnapshotDirty
        sharedSnapshotDirty = false
        let recorder = insights
        Task {
            await self.coordinator.waitForIdle()
            recorder.noteUnigramCount(await host.store.stats().unigrams)
            recorder.flush()
            if shareSnapshot { await EngineHost.writeSharedSnapshot(store: host.store) }
        }
    }

    #if DEBUG
    private var personalStore: PersonalLearner?
    private var personalMode = "-"
    private var debugStatusInFlight = false
    /// Counts and flags only; never any word.
    private func refreshDebugStatus() {
        guard !debugStatusInFlight else { return }
        debugStatusInFlight = true
        let status = engineStatus, mode = personalMode, learner = personalStore
        Task { [weak self] in
            var lines = [status]
            if let learner {
                let st = await learner.store.stats()
                let learning = await learner.isLearning
                let inc = await learner.incognito
                lines.append("personal(\(mode)): u\(st.unigrams) b\(st.bigrams) t\(st.trigrams) learning=\(learning) incog=\(inc.isActive)")
            }
            self?.debugOverlay?.extraLines = lines
            self?.debugStatusInFlight = false
        }
    }
    #endif

    /// The proxy's context can lag an edit by a run-loop turn, so edits schedule one coalesced re-evaluation.
    private func scheduleAutoShift() {
        guard !autoShiftPending else { return }
        autoShiftPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.autoShiftPending = false
            self.updateAutoShift()
        }
    }

    // MARK: Layout

    private func currentTraits() -> LayoutTraits {
        let proxy = textDocumentProxy
        return LayoutTraits(
            displayClass: .phone,
            // A keyboard is always wider than tall, so bounds can't tell; iPhone landscape has a compact height class.
            orientation: traitCollection.verticalSizeClass == .compact ? .landscape : .portrait,
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
        strip.appearance = grid.appearance
        relayoutIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        machine?.cancelAll { _ in }
        swipeCapture.cancel()
        grid.trail.clear()
        coordinator.keyboardWillDisappear()
        settleOnDisappear()
        grid.clearHighlights()
        updateRepeatTimer()
    }

    private var heightKey: String {
        HeightKey.make(displayClass: DisplayClass.phone.rawValue, orientation: currentTraits().orientation.rawValue)
    }

    /// Layout settings from the app (App Group) overridden by what the user did in the keyboard (F11, F1).
    private func currentLayoutSettings() -> LayoutSettings {
        var ls = LayoutSettings()
        ls.numberRow = overrides.numberRow ?? settings.numberRow
        ls.heightScale = CGFloat(liveScale ?? overrides.heightScale(forKey: heightKey) ?? settings.heightScale(forKey: heightKey))
        return ls
    }

    private func dragHandle(translationY dy: CGFloat) {
        let size = view.bounds.size
        guard size.width > 0 else { return }
        let safe = LayoutInsets(top: 0, left: view.safeAreaInsets.left, bottom: view.safeAreaInsets.bottom, right: view.safeAreaInsets.right)
        let traits = currentTraits()
        func h(_ scale: CGFloat) -> CGFloat {
            var ls = currentLayoutSettings(); ls.heightScale = scale
            return LayoutEngine.preferredHeight(width: size.width, safeArea: safe, traits: traits, kind: layoutKind, settings: ls)
        }
        // Dragging up grows the keyboard (it is bottom-anchored).
        liveScale = ResizeMath.scale(forHeight: dragStartHeight - dy, height0: h(0), height1: h(1))
        relayoutIfNeeded()
    }

    private func endDrag() {
        if let s = liveScale { overrides.setHeightScale(s, forKey: heightKey) }
        liveScale = nil
        relayoutIfNeeded()
    }

    private func toggleNumberRow() {
        overrides.setNumberRow(!(overrides.numberRow ?? settings.numberRow))
        lastLayoutKey = nil
        relayoutIfNeeded()
    }

    private func relayoutIfNeeded() {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let safe = LayoutInsets(
            top: 0, left: view.safeAreaInsets.left, bottom: view.safeAreaInsets.bottom, right: view.safeAreaInsets.right
        )
        let traits = currentTraits()
        let ls = currentLayoutSettings()
        let key = LayoutKey(size: size, safe: safe, traits: traits, kind: layoutKind, layoutSettings: ls)
        guard key != lastLayoutKey else { return }
        lastLayoutKey = key

        let want = LayoutEngine.preferredHeight(width: size.width, safeArea: safe, traits: traits, kind: layoutKind, settings: ls)
        if abs((heightConstraint?.constant ?? 0) - want) > 0.5 { heightConstraint?.constant = want }
        let layout = LayoutEngine.layout(containerSize: size, safeArea: safe, traits: traits, kind: layoutKind, settings: ls)
        grid.apply(layout: layout)
        strip.frame = layout.stripFrame
        coordinator.setLayout(layout)
        startEngineLoad(layout: layout)
        handle.frame = CGRect(x: (size.width - ResizeHandleView.size.width) / 2, y: 0, width: ResizeHandleView.size.width, height: ResizeHandleView.size.height)
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
        // A touch that starts on the suggestion strip is a slot tap, not a key press.
        if phase == .began, strip.frame.contains(point), !strip.isShowingAlternates, stripTouchID == nil {
            stripTouchID = id
            return
        }
        if stripTouchID == id {
            if phase == .ended || phase == .cancelled {
                stripTouchID = nil
                if phase == .ended, strip.frame.contains(point), strip.frame.width > 0 {
                    let slot = Int((point.x - strip.frame.minX) / (strip.frame.width / CGFloat(SuggestionStripView.slotCount)))
                    coordinator.tapSlot(slot)
                    feedback()
                    scheduleAutoShift()
                }
            }
            return
        }
        switch phase {
        case .began:
            perfDown = Perf.begin(.touchDownToHighlight)
            coordinator.trackTouch(id: id, at: point)
            machine!.touchDown(id: id, at: point, time: time, emit: sink)
            if let layout = grid.layout { swipeCapture.begin(id: id, at: point, time: time, layout: layout) }
        case .moved:
            if swipeCapture.tracks(id), let layout = grid.layout {
                switch swipeCapture.move(id: id, to: point, time: time, layout: layout) {
                case .began:
                    // Crossed into another key: no longer a key press (F3/F5). Release the cap, insert nothing.
                    machine!.touchCancelled(id: id, emit: sink)
                    coordinator.releaseTouch(id: id)
                    grid.trail.update(points: swipeCapture.trail)
                case .moved:
                    grid.trail.update(points: swipeCapture.trail)
                case .none:
                    break
                }
                if swipeCapture.isSwiping { break }
            }
            coordinator.trackTouch(id: id, at: point)
            machine!.touchMoved(id: id, to: point, emit: sink)
        case .ended:
            if swipeCapture.isSwiping, swipeCapture.tracks(id) {
                finishSwipe(id: id, at: point, time: time)
                break
            }
            if swipeCapture.tracks(id) { _ = swipeCapture.end(id: id, at: point, time: time) }
            coordinator.trackTouch(id: id, at: point)
            perfUp = Perf.begin(.touchUpToInsert)
            machine!.touchUp(id: id, at: point, time: time, emit: sink)
            perfUp = nil // an up that inserts nothing is not a sample (the interval is closed in `handle`)
            coordinator.releaseTouch(id: id)
        case .cancelled:
            if swipeCapture.tracks(id) {
                swipeCapture.cancel()
                grid.trail.finish()
            }
            machine!.touchCancelled(id: id, emit: sink)
            coordinator.releaseTouch(id: id)
        }
        if consumeShiftOnce {
            consumeShiftOnce = false
            if machine!.shift == .once { machine!.setShift(.off, emit: sink) }
        }
        applyDeferredLayerChange()
        updateRepeatTimer()
    }

    /// The swipe finger lifted: fade the trail and hand the path to the typing coordinator (decode, insert word with
    /// auto-space, strip alternatives). A pending shift is consumed like for a typed letter.
    private func finishSwipe(id: Int, at point: CGPoint, time: TimeInterval) {
        let points = swipeCapture.end(id: id, at: point, time: time)
        coordinator.releaseTouch(id: id)
        grid.trail.finish()
        guard let points else { return }
        let shift = grid.shift
        coordinator.swipeEnded(points: points, shift: shift)
        if shift == .once {
            let sink: (KeyEvent) -> Void = { [unowned self] in self.handle($0) }
            machine?.setShift(.off, emit: sink)
        }
        feedback()
        scheduleAutoShift()
    }

    /// Runs inside machine calls: must not touch `machine` (exclusive access).
    private func handle(_ event: KeyEvent) {
        switch event {
        case .highlight(let index, let on):
            grid.setHighlighted(index, on)
            if on, let p = perfDown { Perf.end(p); perfDown = nil }
        case .insert(let text):
            coordinator.insert(text)
            feedback()
            scheduleAutoShift()
        case .deleteBackward:
            coordinator.deleteBackward()
            feedback()
            scheduleAutoShift()
        case .deleteWord:
            coordinator.deleteWord()
            scheduleAutoShift()
        case .returnKey:
            if coordinator.returnKey() { feedback(); scheduleAutoShift() }
        case .advanceKeyboard:
            advanceToNextInputMode()
        case .shiftChanged(let state):
            grid.setShift(state)
        case .alternatesBegan(let keyIndex):
            swipeCapture.cancel() // a long press and a swipe are exclusive (F5)
            // Not `machine`: this runs inside a machine call. The grid holds the current layout.
            guard let layout = grid.layout, keyIndex < layout.keys.count else { break }
            let key = layout.keys[keyIndex]
            let options = KeyAlternates.options(for: key.identity, uppercase: grid.shift != .off) ?? []
            handle.isHidden = true
            strip.beginAlternates(AlternatesSelection(options: options, stripFrame: layout.stripFrame, originRegion: key.touchRegion))
        case .alternatesMoved(let p):
            strip.move(to: p)
        case .alternatesEnded(let p):
            handle.isHidden = false
            if let text = strip.end(at: p) {
                coordinator.insertDirect(text)
                feedback()
                consumeShiftOnce = true
                scheduleAutoShift()
            }
        case .alternatesCancelled:
            strip.cancelAlternates()
            handle.isHidden = false
        case .layerChanged(let kind):
            layoutKind = kind
            layerChangePending = true
            coordinator.endWordLiterally()
        }
        if let p = perfUp, !isHighlight(event) { Perf.end(p); perfUp = nil }
    }

    private func isHighlight(_ e: KeyEvent) -> Bool {
        if case .highlight = e { return true }
        return false
    }

    /// Key click (needs `ClickInputView`, works without Full Access: P-23) and haptic (Full Access only).
    private func feedback() {
        if settings.keyClickSound { UIDevice.current.playInputClick() }
        if hapticsEnabled {
            if haptic == nil { haptic = UIImpactFeedbackGenerator(style: .light) }
            haptic?.impactOccurred()
        }
    }

    private func applyDeferredLayerChange() {
        guard layerChangePending else { return }
        layerChangePending = false
        lastLayoutKey = nil
        relayoutIfNeeded()
        grid.clearHighlights()
        if layoutKind == .letters { updateAutoShift() } // edits made on other layers still affect capitalisation
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

// MARK: - Input plumbing

/// `UIInputView` that opts in to input clicks so `UIDevice.playInputClick()` makes a sound.
final class ClickInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// Adapts the text document proxy to the UIKit-free `TextProxy` used by `InputController`.
final class ProxyAdapter: TextProxy {
    private unowned let controller: UIInputViewController
    init(controller: UIInputViewController) { self.controller = controller }
    var contextBefore: String? { controller.textDocumentProxy.documentContextBeforeInput }
    var hasText: Bool { controller.textDocumentProxy.hasText }
    func insert(_ text: String) { controller.textDocumentProxy.insertText(text) }
    func deleteBackwardOnce() { controller.textDocumentProxy.deleteBackward() }
}

extension AutoCapMode {
    init(_ type: UITextAutocapitalizationType) {
        switch type {
        case .words: self = .words
        case .sentences: self = .sentences
        case .allCharacters: self = .allCharacters
        default: self = .none
        }
    }
}
