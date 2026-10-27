import UIKit
import IBoardCore
import IBoardEngine
import IBoardLayout
import IBoardOTP
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
    private var hapticsEnabled: Bool { SettingsPolicy.hapticsActive(settings: settings, hasFullAccess: hasFullAccess) }
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
    /// Gesture arbiter for the first finger (M5-01): rules out swipes for vertical flicks, starts the spacebar cursor
    /// and the backspace word-delete. `gestureOrigin` is where it went down (view coordinates).
    private var arbiter: GestureArbiter?
    private var arbiterTouchID = -1
    private var gestureOrigin = CGPoint.zero
    private var gestureKeyIndex = -1
    private enum DragMode { case none, cursor(SpacebarCursorDrag), selecting(SpacebarCursorDrag), deleteWords(BackspaceSwipePlan) }
    private var dragMode = DragMode.none
    private var lastStrip = StripContent.empty
    // Strip chips (M6-03 code chip, M6-06 personal info). Codes are read-only from the App Group (works without Full
    // Access, P-23); inserted ids are remembered in memory only, to emulate "clear after insert" because the keyboard
    // cannot delete from the shared store.
    private let otpReader = OTPReader()
    private var consumedCodeIDs = Set<String>()
    private var freshCodes: [StoredCode] = []
    private var chipPlan: [StripChip?] = [nil, nil, nil]
    private var chipTimer: Timer?
    /// Emoji panel + search (M9-01/M9-02 wired): opened by a long press on the 123 key.
    private let emoji = EmojiHost()
    private var emojiPress: DispatchWorkItem?
    private var emojiPressID = -1
    private var emojiPressOrigin = CGPoint.zero
    /// Shift + space selection (M5-05): virtual selection while dragging, then the action row; or a real host selection.
    private enum SelectionUI { case none, dragging(VirtualSelection), actions(VirtualSelection), host(HostSelection) }
    private var selectionUI = SelectionUI.none
    /// True when the current shift state came from a tap on the shift key (not auto-capitalisation): only a manual
    /// shift arms the selection drag, so an auto-capitalised space drag still moves the cursor.
    private var shiftManual = false
    private var applyingAutoShift = false
    /// F7 info saved by the app (M6-06); read-only here.
    private var personalInfo = PersonalInfo.empty
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
        applySettings()
        refreshAppearanceAndTraits()
        applyFieldConfig(forceFieldChange: true)
        applyAppCommands()
        personalInfo = PersonalInfoReader().load() // F7: saved by the app, read-only here (works without Full Access)
        reloadCodes()
        startChipTimer()
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
        emoji.onInsert = { [weak self] text in
            guard let self else { return }
            self.coordinator.insertDirect(text)
            self.feedback()
            self.scheduleAutoShift()
        }
        emoji.onChange = { [weak self] in self?.emojiChanged() }
        coordinator.shiftActive = { [weak self] in (self?.grid.shift ?? .off) != .off } // not `machine`: this runs inside machine calls
        coordinator.onAsyncEdit = { [weak self] in self?.scheduleAutoShift() }
        coordinator.onInsight = { [weak self] event in
            self?.insights.handle(event)
            self?.sharedSnapshotDirty = true
        }
        coordinator.onStripChange = { [weak self] content in
            guard let self else { return }
            self.lastStrip = content
            self.renderStrip()
        }
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
        replanChips()
        refreshHostSelection()
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
        applyingAutoShift = true
        machine!.setShift(coordinator.autoShift(context: textDocumentProxy.documentContextBeforeInput)) {
            [grid] in if case .shiftChanged(let s) = $0 { grid.setShift(s) }
        }
        applyingAutoShift = false
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
            doubleSpacePeriod: !excluded && settings.doubleSpacePeriod
        )
        if excluded || !settings.smartPunctuation { punct.smartQuotes = .no; punct.smartDashes = .no }
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

    /// Pushes the app-written settings (IBoardSettings v3) into the pieces that honour them. Cheap; runs on every
    /// appearance. Haptics are additionally gated on Full Access in `feedback()` (P-23).
    private func applySettings() {
        // F5: hints are the app setting; the keyboard-local key stays as an extra way to turn them on.
        grid.showsFlickHints = settings.flickHints || UserDefaults.standard.bool(forKey: KeyFlick.hintsDefaultsKey)
        // F6: an explicit keyboard-local choice wins, otherwise the app's "start in incognito" default.
        coordinator.setIncognito(incognitoEnabled)
        let policy = SettingsPolicy.autocorrect(for: settings.autocorrect)
        coordinator.autocorrectionEnabled = policy.enabled
        coordinator.autocorrectSettings.aggressiveness = policy.aggressiveness
        // Haptic generator is rebuilt lazily when the strength changed.
        haptic = nil
    }

    private var incognitoEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: Self.incognitoKey) == nil ? settings.incognitoByDefault : d.bool(forKey: Self.incognitoKey)
    }

    private func toggleIncognito() {
        let on = !incognitoEnabled
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
        let emojiLine = emoji.debugLine
        let chipLine = "chips: codes \(freshCodes.count) consumed \(consumedCodeIDs.count) info \(personalInfo.isEmpty ? "none" : "set")"
        Task { [weak self] in
            var lines = [status, chipLine, emojiLine]
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

    // MARK: Strip chips (M6-03, M6-06)

    /// Re-reads the fresh codes from the App Group (cheap, no Full Access needed) and re-plans the chips.
    private func reloadCodes() {
        freshCodes = otpReader.freshCodes(excluding: consumedCodeIDs)
        replanChips()
    }

    private func startChipTimer() {
        chipTimer?.invalidate()
        // A code can arrive while the keyboard is visible (the Message automation runs in the background).
        chipTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            MainActor.assumeIsolated { self.reloadCodes() }
        }
    }

    private func currentChipField() -> ChipField {
        let proxy = textDocumentProxy
        return ChipField(
            contentType: proxy.textContentType?.rawValue,
            keyboard: FieldKeyboardKind(uikitRawValue: proxy.keyboardType?.rawValue ?? 0),
            isSecure: proxy.isSecureTextEntry ?? false,
            isEmpty: !proxy.hasText
        )
    }

    private func replanChips() {
        let plan = ChipPlanner.plan(codes: freshCodes, info: personalInfo, field: currentChipField(), suggestions: lastStrip.slots)
        guard plan != chipPlan else { return }
        chipPlan = plan
        renderStrip()
    }

    /// One tap inserts the chip's text as is (never learned) and hides an inserted code.
    private func insertChip(_ chip: StripChip) {
        coordinator.insertDirect(chip.insert)
        if case .code(let id) = chip.source {
            consumedCodeIDs.insert(id)
            reloadCodes()
        }
        scheduleAutoShift()
    }

    /// The strip shows (highest priority first): the backspace delete preview, chips over suggestions.
    private func renderStrip() {
        if case .deleteWords = dragMode { return } // the delete preview owns the strip until release
        if let texts = emoji.stripTexts {
            strip.emphasizedSlots = []
            strip.bannerText = nil
            strip.actionTitles = []
            strip.slotTexts = texts
            return
        }
        switch selectionUI {
        case .dragging(let sel):
            strip.actionTitles = []
            strip.emphasizedSlots = []
            strip.bannerText = sel.banner
            return
        case .actions(let sel):
            showSelectionActions(banner: SelectionBanner.text(sel.selectedText, count: sel.count, maxPreview: 10))
            return
        case .host(let h):
            showSelectionActions(banner: SelectionBanner.text(h.text, count: h.count, maxPreview: 10))
            return
        case .none:
            strip.bannerText = nil
            strip.actionTitles = []
        }
        var texts = lastStrip.texts
        var emphasized = Set<Int>()
        for (i, chip) in chipPlan.enumerated() where i < texts.count {
            guard let chip else { continue }
            texts[i] = chip.display
            if chip.emphasized { emphasized.insert(i) }
        }
        strip.emphasizedSlots = emphasized
        strip.slotTexts = texts
    }

    // MARK: Emoji (M9)

    private var emojiFrame: CGRect {
        CGRect(x: 0, y: strip.frame.maxY, width: view.bounds.width, height: max(0, view.bounds.height - strip.frame.maxY))
    }

    private func openEmoji() {
        guard !emoji.isOpen, strip.frame.height > 0 else { return }
        machine?.cancelAll { _ in }
        swipeCapture.cancel()
        resetArbiter()
        grid.trail.clear()
        clearSelection()
        // The 123 touch-down already switched the layer: back to the letters, which the search uses.
        if layoutKind != .letters { layoutKind = .letters; lastLayoutKey = nil; relayoutIfNeeded() }
        grid.clearHighlights()
        emoji.open(in: view, frame: emojiFrame, interfaceStyle: grid.appearance == .dark ? .dark : .light)
        view.bringSubviewToFront(strip)
        view.bringSubviewToFront(handle)
    }

    private func emojiChanged() {
        grid.keysHidden = emoji.keysHidden
        handle.isHidden = emoji.isOpen
        renderStrip()
    }

    private func cancelEmojiPress() {
        emojiPress?.cancel()
        emojiPress = nil
        emojiPressID = -1
    }

    /// Long press on 123 (not on other keys): arms a timer that opens the panel.
    private func armEmojiPress(id: Int, at point: CGPoint) {
        guard !emoji.isOpen, let layout = grid.layout, let hit = layout.hit(at: point), hit.keyIndex < layout.keys.count,
              case .layerSwitch(.numbers) = layout.keys[hit.keyIndex].identity else { return }
        cancelEmojiPress()
        emojiPressID = id
        emojiPressOrigin = point
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.emojiPressID == id else { return }
                self.cancelEmojiPress()
                self.openEmoji()
                self.feedback()
            }
        }
        emojiPress = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        emoji.didReceiveMemoryWarning()
    }

    private func showSelectionActions(banner: String) {
        strip.emphasizedSlots = []
        strip.bannerText = banner
        strip.actionTitles = SelectionAction.allCases.map(\.title)
        strip.actionEnabled = SelectionAction.allCases.map { !$0.needsFullAccess || hasFullAccess }
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
        resetArbiter()
        grid.trail.clear()
        coordinator.keyboardWillDisappear()
        selectionUI = .none
        cancelEmojiPress()
        emoji.close()
        settleOnDisappear()
        grid.clearHighlights()
        updateRepeatTimer()
        chipTimer?.invalidate()
        chipTimer = nil
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
        emoji.updateFrame(emojiFrame)
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
                    if emoji.isOpen {
                        emoji.tapStrip(slot: slot)
                        feedback()
                        return
                    }
                    if strip.isShowingActions {
                        if let i = strip.actionIndex(forLocalX: point.x - strip.frame.minX), let a = SelectionAction(rawValue: i) {
                            performSelectionAction(a)
                        }
                        return
                    }
                    if slot >= 0, slot < chipPlan.count, let chip = chipPlan[slot] {
                        insertChip(chip)
                    } else {
                        coordinator.tapSlot(slot)
                    }
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
            armEmojiPress(id: id, at: point)
            machine!.touchDown(id: id, at: point, time: time, emit: sink)
            if let layout = grid.layout, !emoji.isOpen {
                swipeCapture.begin(id: id, at: point, time: time, layout: layout)
                beginArbiter(id: id, at: point, time: time, layout: layout)
            }
        case .moved:
            if emojiPressID == id, hypot(point.x - emojiPressOrigin.x, point.y - emojiPressOrigin.y) > 12 { cancelEmojiPress() }
            if arbiterTouchID == id, routeArbiterMove(id: id, to: point, time: time, sink: sink) { break }
            if swipeCapture.tracks(id), let layout = grid.layout {
                switch swipeCapture.move(id: id, to: point, time: time, layout: layout, allowSwipe: settings.swipeTyping && arbiter?.decided == .swipeTyping) {
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
            if emojiPressID == id { cancelEmojiPress() }
            if swipeCapture.isSwiping, swipeCapture.tracks(id) {
                resetArbiter()
                finishSwipe(id: id, at: point, time: time)
                break
            }
            if arbiterTouchID == id, finishArbiter(id: id, at: point, time: time, sink: sink) { break }
            if swipeCapture.tracks(id) { _ = swipeCapture.end(id: id, at: point, time: time) }
            coordinator.trackTouch(id: id, at: point)
            perfUp = Perf.begin(.touchUpToInsert)
            machine!.touchUp(id: id, at: point, time: time, emit: sink)
            perfUp = nil // an up that inserts nothing is not a sample (the interval is closed in `handle`)
            coordinator.releaseTouch(id: id)
        case .cancelled:
            if emojiPressID == id { cancelEmojiPress() }
            if arbiterTouchID == id { cancelDrag() }
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

    // MARK: Gesture arbiter (M5-01) -> flicks (M5-04), spacebar cursor (M5-02), backspace swipe-delete (M5-03)

    private func beginArbiter(id: Int, at point: CGPoint, time: TimeInterval, layout: KeyboardLayout) {
        guard arbiter == nil, let hit = layout.hit(at: point), hit.keyIndex < layout.keys.count else { return }
        let identity = layout.keys[hit.keyIndex].identity
        let start: GestureStart
        switch identity {
        case .letter: start = .letter
        case .space: start = .space
        case .delete: start = .delete
        default: return
        }
        arbiter = GestureArbiter(start: start, origin: point, time: time, keyHeight: layout.metrics.keyHeight,
                                 hasAlternates: KeyAlternates.options(for: identity) != nil,
                                 shiftArmed: identity == .space && shiftManual && grid.shift == .once)
        arbiterTouchID = id
        gestureOrigin = point
        gestureKeyIndex = hit.keyIndex
        dragMode = .none
    }

    private func resetArbiter() {
        arbiter = nil
        arbiterTouchID = -1
        gestureKeyIndex = -1
        let wasDeleting: Bool
        if case .deleteWords = dragMode { wasDeleting = true } else { wasDeleting = false }
        if case .selecting = dragMode { finalizeSelectionDrag() }
        dragMode = .none
        if wasDeleting { renderStrip() }
    }

    /// Feeds a move to the arbiter. Returns true when the move was consumed by a cursor / delete drag.
    private func routeArbiterMove(id: Int, to point: CGPoint, time: TimeInterval, sink: (KeyEvent) -> Void) -> Bool {
        guard var a = arbiter, let layout = grid.layout else { return false }
        var crossed = false
        if a.start == .letter, let hit = layout.hit(at: point), hit.keyIndex != gestureKeyIndex,
           case .letter = layout.keys[hit.keyIndex].identity { crossed = true }
        let decided = a.move(to: point, time: time, crossedKeys: crossed)
        arbiter = a
        switch decided {
        case .spacebarCursor?:
            // The space key is released without typing a space; the drag now owns the touch.
            machine!.touchCancelled(id: id, emit: sink)
            coordinator.releaseTouch(id: id)
            // Starts at the touch-down point so travel up to the decision (and sparse move events) still counts.
            dragMode = .cursor(SpacebarCursorDrag(start: gestureOrigin, time: time - 0.1))
        case .spacebarSelection?:
            machine!.touchCancelled(id: id, emit: sink)
            coordinator.releaseTouch(id: id)
            beginSelection(origin: gestureOrigin, time: time)
        case .backspaceSwipeDelete?:
            // Touch-down already deleted one character and started the repeat; the repeat stops here.
            machine!.touchCancelled(id: id, emit: sink)
            coordinator.releaseTouch(id: id)
            dragMode = .deleteWords(BackspaceSwipePlan(words: 0, graphemes: 0, preview: ""))
        default: break
        }
        switch dragMode {
        case .cursor(var drag):
            let step = drag.move(to: point, time: time)
            dragMode = .cursor(drag)
            if step.horizontal != 0 || step.vertical != 0 {
                if coordinator.moveCursor(graphemes: step.horizontal, lines: step.vertical) { feedback() }
            }
            return true
        case .selecting(var drag):
            let step = drag.move(to: point, time: time)
            dragMode = .selecting(drag)
            extendSelection(step)
            return true
        case .deleteWords:
            updateDeletePreview(at: point)
            return true
        case .none:
            return false
        }
    }

    // MARK: Shift + space selection (M5-05)

    /// Anchor = the cursor now. The context is read once and kept in memory for the gesture only.
    private func beginSelection(origin: CGPoint, time: TimeInterval) {
        let proxy = textDocumentProxy
        selectionUI = .dragging(VirtualSelection(before: proxy.documentContextBeforeInput ?? "",
                                                 after: proxy.documentContextAfterInput ?? ""))
        dragMode = .selecting(SpacebarCursorDrag(start: origin, time: time - 0.1))
        consumeShiftOnce = true // Shift is consumed: the next letter is not capitalised
        renderStrip()
    }

    private func extendSelection(_ step: SpacebarCursorDrag.Step) {
        guard step.horizontal != 0 || step.vertical != 0, case .dragging(var sel) = selectionUI else { return }
        let offset = sel.move(graphemes: step.horizontal, lines: step.vertical)
        selectionUI = .dragging(sel)
        if offset != 0 { coordinator.adjustCursor(utf16: offset); feedback() }
        renderStrip()
    }

    /// Finger lifted: a non-empty selection gets the action row.
    private func finalizeSelectionDrag() {
        guard case .dragging(let sel) = selectionUI else { return }
        selectionUI = sel.isEmpty ? .none : .actions(sel)
        renderStrip()
    }

    private func clearSelection() {
        if case .none = selectionUI { return }
        selectionUI = .none
        renderStrip()
    }

    /// A real host selection (`selectedText`) gets the same action row; it goes away with the selection.
    private func refreshHostSelection() {
        switch selectionUI {
        case .dragging, .actions: return // our own virtual selection owns the strip
        default: break
        }
        if let t = textDocumentProxy.selectedText, !t.isEmpty {
            if case .host(let h) = selectionUI, h.text == t { return }
            selectionUI = .host(HostSelection(text: t))
        } else if case .host = selectionUI {
            selectionUI = .none
        } else { return }
        renderStrip()
    }

    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        refreshHostSelection()
    }

    private func performSelectionAction(_ action: SelectionAction) {
        if action.needsFullAccess, !hasFullAccess { return } // pasteboard strings need Full Access (P-23)
        switch selectionUI {
        case .actions(var sel):
            guard let edit = sel.edit(for: action) else { return }
            if let text = edit.pasteboardText { UIPasteboard.general.string = text }
            if edit.moveUTF16 != 0 || edit.deleteGraphemes != 0 || edit.insert != nil { coordinator.applySelectionEdit(edit) }
            sel.apply(action, edit: edit)
            selectionUI = edit.endsSelection || sel.isEmpty ? .none : .actions(sel)
        case .host(let host):
            guard let edit = host.edit(for: action) else { return }
            if let text = edit.pasteboardText { UIPasteboard.general.string = text }
            if edit.deleteGraphemes != 0 || edit.insert != nil { coordinator.applySelectionEdit(edit) }
            // A re-inserted case change is no longer a host selection; the strip returns to normal.
            selectionUI = edit.endsSelection || edit.insert != nil ? .none : .host(host)
        default: return
        }
        feedback()
        scheduleAutoShift()
        renderStrip()
    }

    private func updateDeletePreview(at point: CGPoint) {
        let extra = max(0, gestureOrigin.x - point.x - GestureThresholds().backspaceDragStart)
        let plan = BackspaceSwipePlan.plan(before: coordinator.contextBeforeForPreview, extraDistance: extra)
        if case .deleteWords(let old) = dragMode, old == plan { return }
        dragMode = .deleteWords(plan)
        let preview = plan.preview.replacingOccurrences(of: "\n", with: " ")
        strip.emphasizedSlots = []
        strip.slotTexts = ["", preview, ""]
    }

    /// Lift of the arbiter's touch. Returns true when the gesture was fully handled here (flick / drag end).
    private func finishArbiter(id: Int, at point: CGPoint, time: TimeInterval, sink: (KeyEvent) -> Void) -> Bool {
        guard var a = arbiter, let layout = grid.layout else { resetArbiter(); return false }
        let keyHeight = layout.metrics.keyHeight
        let origin0 = gestureOrigin
        // Released far above / below the key row it was dragged away: counts as "onto the keys" for backspace.
        let away = abs(point.y - gestureOrigin.y) > 2 * keyHeight
        let g = a.end(at: point, time: time, endedOverKeys: away)
        // A drag decided only by the lift (no move events in between): the same as if it had been decided live.
        if case .none = dragMode {
            if g == .spacebarCursor {
                machine!.touchCancelled(id: id, emit: sink)
                coordinator.releaseTouch(id: id)
                dragMode = .cursor(SpacebarCursorDrag(start: origin0, time: time - 0.1))
            } else if g == .spacebarSelection {
                machine!.touchCancelled(id: id, emit: sink)
                coordinator.releaseTouch(id: id)
                beginSelection(origin: origin0, time: time)
            } else if g == .backspaceSwipeDelete || g == .backspaceSwipeCancel {
                machine!.touchCancelled(id: id, emit: sink)
                coordinator.releaseTouch(id: id)
                dragMode = .deleteWords(BackspaceSwipePlan(words: 0, graphemes: 0, preview: ""))
            }
        }
        if case .cursor(var drag) = dragMode {
            // The lift point is a last sample (a quick drag may have had no move events at all).
            let step = drag.move(to: point, time: time)
            if step.horizontal != 0 || step.vertical != 0 { _ = coordinator.moveCursor(graphemes: step.horizontal, lines: step.vertical) }
        }
        if case .selecting(var drag) = dragMode {
            let step = drag.move(to: point, time: time)
            extendSelection(step)
        }
        if case .deleteWords = dragMode { updateDeletePreview(at: point) }
        let mode = dragMode
        let startIndex = gestureKeyIndex
        let origin = gestureOrigin
        resetArbiter()
        switch g {
        case .spacebarCursor, .spacebarSelection:
            _ = mode // cursor already moved live; the space key was cancelled
            return true
        case .backspaceSwipeDelete:
            if case .deleteWords(let plan) = mode {
                coordinator.deleteRun(graphemes: plan.graphemes)
                feedback()
                scheduleAutoShift()
            }
            return true
        case .backspaceSwipeCancel:
            return true
        case .flickUp, .flickDown:
            guard startIndex >= 0, startIndex < layout.keys.count else { return false }
            let text = KeyFlick.text(for: layout.keys[startIndex].identity, direction: g == .flickUp ? .up : .down,
                                     uppercase: grid.shift != .off)
            if swipeCapture.tracks(id) { swipeCapture.cancel() }
            grid.trail.clear()
            if let text {
                machine!.touchCancelled(id: id, emit: sink)
                coordinator.releaseTouch(id: id)
                coordinator.insertDirect(text)
                feedback()
                consumeShiftOnce = true
                scheduleAutoShift()
                return true
            }
            // No secondary character: a normal tap on the key the finger started on.
            machine!.touchMoved(id: id, to: origin, emit: sink)
            return false
        default:
            return false
        }
    }

    private func cancelDrag() { resetArbiter() }

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
        if emoji.mode == .search {
            switch event {
            case .insert(let text): _ = emoji.handleKey(insert: text); feedback(); return
            case .deleteBackward: _ = emoji.handleDeleteBackward(); feedback(); return
            case .deleteWord: _ = emoji.handleDeleteWord(); return
            case .returnKey: _ = emoji.handleReturn(); feedback(); return
            default: break
            }
        }
        switch event {
        case .highlight(let index, let on):
            grid.setHighlighted(index, on)
            if on, let p = perfDown { Perf.end(p); perfDown = nil }
        case .insert(let text):
            clearSelection()
            coordinator.insert(text)
            feedback()
            scheduleAutoShift()
        case .deleteBackward:
            clearSelection()
            coordinator.deleteBackward()
            feedback()
            scheduleAutoShift()
        case .deleteWord:
            coordinator.deleteWord()
            scheduleAutoShift()
        case .returnKey:
            clearSelection()
            if coordinator.returnKey() { feedback(); scheduleAutoShift() }
        case .advanceKeyboard:
            advanceToNextInputMode()
        case .shiftChanged(let state):
            shiftManual = state != .off && !applyingAutoShift
            grid.setShift(state)
        case .alternatesBegan(let keyIndex):
            swipeCapture.cancel() // a long press and a swipe are exclusive (F5)
            resetArbiter()
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
                if emoji.mode == .search { _ = emoji.handleKey(insert: text); feedback(); break }
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
            if haptic == nil { haptic = UIImpactFeedbackGenerator(style: SettingsPolicy.impactStyle(for: settings.hapticIntensity)) }
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
    var contextAfter: String? { controller.textDocumentProxy.documentContextAfterInput }
    func adjustPosition(byUTF16 offset: Int) { controller.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) }
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


extension SettingsPolicy {
    /// Strength of the key haptic (light / medium / strong -> UIKit light / medium / heavy impact).
    static func impactStyle(for intensity: HapticIntensity) -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch intensity {
        case .light: .light
        case .medium: .medium
        case .strong: .heavy
        }
    }
}
