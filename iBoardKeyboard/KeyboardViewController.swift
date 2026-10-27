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
    /// Themed backdrop behind keys and strip (F10); draws nothing for the system material (Native, P-22).
    private let backdropView = ThemeBackdropView()
    private let themeStore = ThemeStore()
    /// The selected theme from the App Group (written by the app's ThemeStore; Native when absent or invalid).
    private var theme = ThemePresets.native
    private var appliedSkin: KeyboardSkin?
    private var appliedBackdropPhoto: URL?
    private let strip = SuggestionStripView()
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
    private var autoShiftPending = false
    private lazy var coordinator = TypingCoordinator(input: input)
    private var engineLoadStarted = false
    private var engineLoadAttempts = 0
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
    private var stripTouchIgnored = false
    /// M3-04: long-press on a suggestion opens Forget / Never correct / Cancel in the strip.
    private var suggestionMenu: SuggestionMenu?
    private var stripHoldTimer: Timer?
    private var stripTouchStart = CGPoint.zero
    /// Swipe typing capture (M4-01): one finger at a time; trail drawn by `grid.trail`.
    private var swipeCapture = SwipeCapture()
    /// Gesture arbiter for the first finger (M5-01): rules out swipes for vertical flicks, starts the spacebar cursor
    /// and the backspace word-delete. `gestureOrigin` is where it went down (view coordinates).
    private var arbiter: GestureArbiter?
    private var arbiterTouchID = -1
    private var gestureOrigin = CGPoint.zero
    /// Backspace swipe: the words to delete are marked in the host field while dragging (see `MarkedDeletePreview`).
    private lazy var markedDelete = MarkedDeletePreview(proxy: ProxyAdapter(controller: self), style: deletePreviewStyle == "marked" ? .marked : .live)
    /// Left context captured when the drag starts; every plan of the drag is computed from it (the proxy lags edits).
    private var deleteBaseContext: String?
    /// A host that ignored marked text was seen: no more in-field previews until the keyboard is recreated.
    private var markedDeleteUnsupported = false
    /// `UserDefaults` `iBoard.deletePreviewStyle`: "live" (default: words vanish as you drag), "marked" (marked text,
    /// no visible highlight in tested hosts) or "strip" (suggestion strip only).
    private var deletePreviewStyle: String { UserDefaults.standard.string(forKey: "iBoard.deletePreviewStyle") ?? "live" }
    private var markedDeleteEnabled: Bool { deletePreviewStyle != "strip" }
    private var gestureKeyIndex = -1
    private enum DragMode { case none, cursor(SpacebarCursorDrag), selecting(SpacebarCursorDrag), deleteWords(BackspaceSwipePlan) }
    private var dragMode = DragMode.none {
        didSet {
            switch dragMode {
            case .cursor, .selecting: grid.setCursorMode(true)
            default: grid.setCursorMode(false)
            }
        }
    }
    /// First-run gesture tips in the strip (Next / Skip); remembered in the extension's own defaults.
    private var coach = CoachStore.load()
    private var lastStrip = StripContent.empty
    // Strip chips (M6-03 code chip, M6-06 personal info). Codes are read-only from the App Group (works without Full
    // Access, P-23); inserted ids are remembered in memory only, to emulate "clear after insert" because the keyboard
    // cannot delete from the shared store.
    private let otpReader = OTPReader()
    private var consumedCodeIDs = Set<String>()
    private var freshCodes: [StoredCode] = []
    private var chipPlan: [StripChip?] = [nil, nil, nil]
    /// M6-05: the pasteboard held no code; no more offers until the field changes.
    private var clipboardMissed = false
    /// M9-03: clipboard history (Full Access only), loaded lazily and kept in the extension container.
    private var clipboard = ClipboardHistory()
    private lazy var clipboardStore = ClipboardStore(url: EngineHost.localDirectory().appendingPathComponent("clipboard.json"))
    private var clipboardLoaded = false
    private var clipboardReading = false
    private var chipTimer: Timer?
    /// M9-03: the full clipboard history panel (opened from the clipboard chip; Full Access only).
    private let clipboardPanel = ClipboardHost()
    /// M3-05: system lexicon (Text Replacements + contact names) from `requestSupplementaryLexicon`. Entries and the
    /// derived snapshot live in memory only; only an integer fingerprint is persisted (extension-local defaults).
    private var lexiconEntries: [SystemLexiconEntry]?
    private var lexiconSnapshot = SystemLexiconSnapshot.empty
    private var lexiconRefreshing = false
    static let lexiconFingerprintKey = "iBoard.systemLexicon.fingerprint"
    /// Emoji panel + search (M9-01/M9-02 wired): opened by the emoji button at the trailing end of the strip.
    private let emoji = EmojiHost()
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
        #if DEBUG || IBOARD_PERF
        PerfMetricsHook.noteAppear()
        #endif
        settings = SettingsStore().load()
        applySettings()
        theme = themeStore.loadSelected() // Native on any problem (D-07); works without Full Access (P-23)
        appliedSkin = nil
        refreshAppearanceAndTraits()
        applyFieldConfig(forceFieldChange: true)
        DispatchQueue.main.async { [weak self] in self?.coordinator.resync() } // never come back to an empty strip
        applyAppCommands()
        personalInfo = PersonalInfoReader().load() // F7: saved by the app, read-only here (works without Full Access)
        reloadCodes()
        recordClipboardIfChanged()
        startChipTimer()
        requestSystemLexicon()
        #if DEBUG
        // Debug-only exposure for UI tests / inspection: no typed text involved.
        grid.accessibilityValue = "haptics=\(settings.haptics) fullAccess=\(hasFullAccess)"
        #endif
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear // P-22: the system draws the keyboard backdrop
        backdropView.frame = view.bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdropView) // below the grid
        for name in [UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                     UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
                     UIAccessibility.boldTextStatusDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAppearanceAndTraits() }
            }
        }
        grid.frame = view.bounds
        grid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        grid.accessibilityIdentifier = "key-grid"
        strip.onAccessibilityActivate = { [weak self] local in
            guard let self else { return }
            let p = CGPoint(x: self.strip.frame.minX + local.x, y: self.strip.frame.minY + local.y)
            let t = ProcessInfo.processInfo.systemUptime
            self.handleTouch(.began, -8, p, t)
            self.handleTouch(.ended, -8, p, t + 0.02)
        }
        grid.touchHandler = { [weak self] phase, id, point, time in self?.handleTouch(phase, id, point, time) }
        view.addSubview(grid)
        view.addSubview(strip) // above the grid; not interactive, so touches still reach the grid
        // F12: pinch toggles the Duo split for the current orientation. Must not steal or delay key touches.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delaysTouchesBegan = false
        pinch.delaysTouchesEnded = false
        view.addGestureRecognizer(pinch)
        emoji.onInsert = { [weak self] text in
            guard let self else { return }
            self.coordinator.insertDirect(text)
            self.feedback()
            self.scheduleAutoShift()
        }
        emoji.onChange = { [weak self] in self?.emojiChanged() }
        wireClipboardPanel()
        strip.onAccessibilityAction = { [weak self] slot, index in self?.performStripAccessibilityAction(slot: slot, index: index) }
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
        #if DEBUG || IBOARD_PERF
        PerfMetricsHook.start()
        #endif
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
        // A shift the user just tapped stays until a letter uses it (a late textDidChange must not undo it).
        if machine!.shift == .once && shiftManual { return }
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
        // The Swift overlay types `documentIdentifier` as a non-optional UUID, but some hosts hand back nil and the
        // bridge then traps (EXC_BREAKPOINT in UUID._unconditionallyBridgeFromObjectiveC). Read it through KVC and a
        // conditional cast instead; no id simply means "same document".
        let doc = (proxy as? NSObject)?.value(forKey: "documentIdentifier") as? UUID
        if forceFieldChange || doc != lastDocumentID {
            lastDocumentID = doc
            clipboardMissed = false
            suggestionMenu = nil
            coordinator.fieldDidChange(config)
        } else {
            coordinator.updateConfig(config)
        }
    }

    /// Pushes the app-written settings (IBoardSettings v3) into the pieces that honour them. Cheap; runs on every
    /// appearance. Haptics are additionally gated on Full Access in `feedback()` (P-23).
    private func applySettings() {
        machine?.longPressDelay = settings.longPressDelay.seconds
        // F5: hints are the app setting; the keyboard-local key stays as an extra way to turn them on.
        grid.showsFlickHints = settings.flickHints || UserDefaults.standard.bool(forKey: KeyFlick.hintsDefaultsKey)
        // F6: an explicit keyboard-local choice wins, otherwise the app's "start in incognito" default.
        coordinator.setIncognito(incognitoEnabled)
        let policy = SettingsPolicy.autocorrect(for: settings.autocorrect)
        coordinator.autocorrectionEnabled = policy.enabled
        coordinator.autocorrectSettings.aggressiveness = policy.aggressiveness
        // Haptic generator is rebuilt lazily when the strength changed.
        hapticGenerators = [:]
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
                // A failed load (lexicon unreadable under memory pressure, ...) used to leave the keyboard without
                // suggestions for the rest of its life: try again a few times, a little later each time.
                if loaded.engine == nil, self.engineLoadAttempts < 3 {
                    self.engineLoadAttempts += 1
                    self.engineLoadStarted = false
                    let delay = Double(self.engineLoadAttempts) * 2
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, let layout = self.grid.layout else { return }
                        self.startEngineLoad(layout: layout)
                    }
                    return
                }
                self.host = loaded
                self.coordinator.setEngine(loaded.engine)
                self.coordinator.setSwipeDecoder(loaded.swipe)
                self.coordinator.setLearner(loaded.learner)
                self.coordinator.setTouchModel(loaded.touchModel, store: loaded.touchStore)
                self.applyAppCommands()
                self.refreshSystemLexicon() // seeds contact names into the personal model now that the store exists
                // Build the emoji panel hidden shortly after the keyboard is ready: opening it is then instant.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, !self.emoji.isOpen, self.strip.frame.height > 0 else { return }
                    self.emoji.prewarm(in: self.view, frame: self.emojiFrame, interfaceStyle: self.grid.appearance == .dark ? .dark : .light)
                    self.view.bringSubviewToFront(self.strip)
                }
                #if DEBUG
                self.engineStatus = loaded.engine == nil
                    ? "engine: none (stub)" : "engine: bundled \(loaded.wordCount) words + hinglish \(loaded.hinglishWordCount)"
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
        if clipboardLoaded { clipboardStore.save(clipboard) } // drops expired items from disk
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
        let t = currentTraits()
        let ls = currentLayoutSettings()
        let sz = screenSize ?? .zero
        let displayLine = "display: \(t.displayClass.rawValue) \(t.orientation.rawValue) \(Int(sz.width))x\(Int(sz.height)) view \(Int(view.bounds.width))x\(Int(view.bounds.height)) split=\(ls.isSplit(for: t.orientation)) fill=\(ls.fillToFold)"
        let chipLine = "chips: codes \(freshCodes.count) consumed \(consumedCodeIDs.count) info \(personalInfo.isEmpty ? "none" : "set")"
        Task { [weak self] in
            var lines = [status, displayLine, chipLine, emojiLine]
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
            MainActor.assumeIsolated { self.reloadCodes(); self.recordClipboardIfChanged() }
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
        let plan = ChipPlanner.plan(codes: freshCodes, info: personalInfo, field: currentChipField(), suggestions: lastStrip.slots,
                                   clipboardOffer: hasFullAccess && !clipboardMissed,
                                   clipboardItem: (hasFullAccess && settings.clipboardHistory) ? clipboard.newest(at: Date())?.text : nil)
        guard plan != chipPlan else { return }
        chipPlan = plan
        renderStrip()
    }

    /// Loads the stored history once and applies the owner's retention setting (settings.clipboardTTL).
    private func loadClipboardIfNeeded() {
        if !clipboardLoaded { clipboard = clipboardStore.load(); clipboardLoaded = true }
        clipboard.ttl = settings.clipboardTTL.seconds
    }

    /// M9-03: records a new pasteboard item while the keyboard is visible. `changeCount` is free to read; the string is
    /// read only when it changed, off the main thread (the first read may show the system paste prompt, P-25).
    private func recordClipboardIfChanged() {
        guard hasFullAccess, settings.clipboardHistory, !clipboardReading else { return }
        loadClipboardIfNeeded()
        let count = UIPasteboard.general.changeCount
        guard clipboard.needsRead(changeCount: count) else { return }
        // Never record from secure fields' context: nothing is read while a password field is focused.
        if textDocumentProxy.isSecureTextEntry ?? false { return }
        clipboardReading = true
        Task.detached { [weak self] in
            let text = UIPasteboard.general.hasStrings ? UIPasteboard.general.string : nil
            await MainActor.run {
                guard let self else { return }
                self.clipboardReading = false
                self.clipboard.record(text, changeCount: count, at: Date())
                self.clipboardStore.save(self.clipboard)
                self.replanChips()
            }
        }
    }

    /// M6-05: reads the pasteboard only now (the first read may show the system paste prompt, P-25), off the main
    /// thread, and inserts a code when it holds one; otherwise the chip hides until the field changes.
    private func pasteClipboardCode() {
        Task.detached { [weak self] in
            let text = UIPasteboard.general.string
            let code = ClipboardCode.extract(from: text)
            await MainActor.run {
                guard let self else { return }
                if let code { self.coordinator.insertDirect(code); self.scheduleAutoShift() }
                else { self.clipboardMissed = true; self.replanChips() }
            }
        }
    }

    /// One tap inserts the chip's text as is (never learned) and hides an inserted code.
    private func insertChip(_ chip: StripChip) {
        if chip.source == .clipboardCode { pasteClipboardCode(); return }
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
        if let menu = suggestionMenu {
            strip.emphasizedSlots = []
            strip.bannerShare = 0.3
            strip.bannerText = menu.banner
            strip.actionTitles = SuggestionMenu.actionTitles
            strip.actionEnabled = []
            return
        }
        if clipboardPanel.isOpen {
            strip.emphasizedSlots = []
            strip.boldSlots = []
            strip.bannerText = nil
            strip.actionTitles = []
            strip.searchField = nil
            strip.slotAccessibilityActions = [:]
            strip.slotTexts = ["", "", ""]
            return
        }
        if let texts = emoji.stripTexts {
            strip.emphasizedSlots = []
            strip.bannerText = nil
            strip.actionTitles = []
            strip.searchField = emoji.stripField
            strip.slotTexts = texts
            return
        }
        strip.searchField = nil
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
            strip.bannerShare = 0.36
        }
        if !coach.isDone, let tip = coach.text {
            strip.emphasizedSlots = []
            strip.boldSlots = []
            strip.bannerShare = 0.72
            strip.bannerText = tip
            strip.actionTitles = coach.actionTitles
            strip.actionEnabled = []
            return
        }
        var texts = lastStrip.texts
        var bold = Set<Int>()
        for (i, slot) in lastStrip.slots.enumerated() where i < texts.count && slot?.role == .best { bold.insert(i) }
        // Right after an autocorrection the first slot offers to undo it (one tap = backspace right after it).
        let undo = chipPlan[0] == nil ? coordinator.undoableAutocorrection : nil
        if let undo, !texts.isEmpty { texts[0] = "↩\u{FE0E} \(undo)"; bold.remove(0) }
        strip.boldSlots = bold
        var emphasized = Set<Int>()
        for (i, chip) in chipPlan.enumerated() where i < texts.count {
            guard let chip else { continue }
            texts[i] = chip.display
            if chip.emphasized { emphasized.insert(i) }
        }
        strip.emphasizedSlots = emphasized
        strip.slotTexts = texts
        strip.slotAccessibilityActions = stripAccessibilityActions()
    }

    // MARK: VoiceOver actions on the strip (M13-01)

    /// Custom actions per slot: the clipboard chip opens the history, plain suggestions can be forgotten / never
    /// corrected (what the long-press menu does, which VoiceOver users cannot reach by touch).
    private func stripAccessibilityActions() -> [Int: [String]] {
        var out: [Int: [String]] = [:]
        for slot in 0..<SuggestionStripView.slotCount {
            if slot < chipPlan.count, let chip = chipPlan[slot] {
                if chip.source == .clipboardItem { out[slot] = ["Open clipboard history"] }
            } else if coach.isDone, !(slot == 0 && coordinator.undoableAutocorrection != nil), slot < lastStrip.slots.count,
                      SuggestionMenu.menu(for: lastStrip.slots[slot], at: slot) != nil {
                out[slot] = ["Forget suggestion", "Never correct"]
            }
        }
        return out
    }

    private func performStripAccessibilityAction(slot: Int, index: Int) {
        if slot < chipPlan.count, chipPlan[slot]?.source == .clipboardItem { openClipboardPanel(); return }
        guard slot < lastStrip.slots.count, let menu = SuggestionMenu.menu(for: lastStrip.slots[slot], at: slot) else { return }
        suggestionMenu = menu
        performSuggestionMenu(index == 0 ? .forget : .neverCorrect)
        UIAccessibility.post(notification: .announcement, argument: index == 0 ? "Suggestion forgotten" : "Will never correct")
    }

    // MARK: Clipboard history panel (M9-03)

    private func wireClipboardPanel() {
        clipboardPanel.onPaste = { [weak self] text in
            guard let self else { return }
            self.coordinator.insertDirect(text)
            self.feedback()
            self.scheduleAutoShift()
            self.closeClipboardPanel()
        }
        clipboardPanel.onTogglePin = { [weak self] id, pinned in
            guard let self else { return }
            self.clipboard.setPinned(id, pinned)
            self.clipboardEdited()
            UIAccessibility.post(notification: .announcement, argument: pinned ? "Pinned" : "Unpinned")
        }
        clipboardPanel.onDelete = { [weak self] id in
            guard let self else { return }
            self.clipboard.remove(id)
            self.clipboardEdited()
            UIAccessibility.post(notification: .announcement, argument: "Deleted")
        }
        clipboardPanel.onClearAll = { [weak self] in
            guard let self else { return }
            self.clipboard.clearAll()
            self.clipboardEdited()
            self.feedback(.action)
            UIAccessibility.post(notification: .announcement, argument: "Clipboard history cleared")
        }
        clipboardPanel.onClose = { [weak self] in self?.closeClipboardPanel() }
    }

    private func clipboardEdited() {
        clipboardStore.save(clipboard)
        clipboardPanel.update(model: ClipboardPanelModel(history: clipboard, now: Date()))
        replanChips()
    }

    private func openClipboardPanel() {
        guard hasFullAccess, settings.clipboardHistory, !clipboardPanel.isOpen, !emoji.isOpen, strip.frame.height > 0 else { return }
        loadClipboardIfNeeded()
        machine?.cancelAll { _ in }
        swipeCapture.cancel()
        resetArbiter()
        grid.trail.clear()
        clearSelection()
        grid.clearHighlights()
        suggestionMenu = nil
        clipboardPanel.open(in: view, frame: emojiFrame, model: ClipboardPanelModel(history: clipboard, now: Date()),
                            skin: appliedSkin ?? .native(.light), style: grid.appearance == .dark ? .dark : .light)
        grid.keysHidden = true
        view.bringSubviewToFront(strip)
        renderStrip()
    }

    private func closeClipboardPanel() {
        guard clipboardPanel.isOpen else { return }
        clipboardPanel.close()
        grid.keysHidden = emoji.keysHidden
        renderStrip()
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    // MARK: System lexicon (M3-05)

    /// Asks the system for Text Replacements and contact names (once per appearance; cheap). The callback may arrive off
    /// the main thread (P-25), so it only copies plain strings.
    private func requestSystemLexicon() {
        // `@Sendable` keeps the closure nonisolated: UIKit calls it on a background queue (with Full Access the request
        // goes over XPC), and a closure formed here would otherwise inherit @MainActor and trap in
        // `_dispatch_assert_queue_fail` (same crash class as the earlier `lexicon()` / `pasteTest()` probes).
        requestSupplementaryLexicon { @Sendable [weak self] lexicon in
            let entries = lexicon.entries.map { SystemLexiconEntry(userInput: $0.userInput, documentText: $0.documentText) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.lexiconEntries = entries
                    self?.refreshSystemLexicon()
                }
            }
        }
    }

    /// Rebuilds the snapshot (always, for the expansion lookups) and, once the personal store exists, seeds new contact
    /// names through `SystemLexiconImporter`. The persisted fingerprint keeps an unchanged address book free.
    private func refreshSystemLexicon() {
        guard let entries = lexiconEntries, !lexiconRefreshing else { return }
        guard let host else { lexiconSnapshot = SystemLexiconSnapshot(entries: entries); return }
        lexiconRefreshing = true
        let previous = SystemLexiconFingerprintStore.decode(UserDefaults.standard.string(forKey: Self.lexiconFingerprintKey))
        let importer = SystemLexiconImporter(source: FixedLexiconSource(list: entries), store: host.store, previousFingerprint: previous)
        Task { [weak self] in
            let result = await importer.refresh()
            let snapshot = await importer.current
            if result.namesAdded > 0 { await host.engine?.refreshPersonal() }
            guard let self else { return }
            self.lexiconSnapshot = snapshot
            UserDefaults.standard.set(SystemLexiconFingerprintStore.encode(result.fingerprint), forKey: Self.lexiconFingerprintKey)
            self.lexiconRefreshing = false
        }
    }

    /// Space after a Text Replacement shortcut ("omw") inserts the expansion instead. Returns true when it did.
    /// Never in secure fields, emoji search, or with autocorrection turned off in settings.
    private func expandTextReplacementIfAny() -> Bool {
        guard !lexiconSnapshot.replacements.isEmpty, emoji.mode != .search, !clipboardPanel.isOpen else { return false }
        let token = coordinator.typedToken
        guard TextReplacementPolicy.shouldExpand(token: token, secure: textDocumentProxy.isSecureTextEntry ?? false,
                                                 enabled: coordinator.autocorrectionEnabled),
              let expansion = lexiconSnapshot.expansion(for: token) else { return false }
        coordinator.expandShortcut(expansion)
        return true
    }

    // MARK: Suggestion menu (M3-04)

    private func scheduleStripHold(at point: CGPoint) {
        stripHoldTimer?.invalidate()
        guard suggestionMenu == nil, !emoji.isOpen, coach.isDone, !strip.isShowingActions, !stripTouchIgnored else { return }
        stripHoldTimer = Timer.scheduledTimer(withTimeInterval: SuggestionMenu.holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSuggestionMenu(at: point) }
        }
    }

    private func openSuggestionMenu(at point: CGPoint) {
        guard stripTouchID != nil, strip.frame.width > 0, suggestionMenu == nil else { return }
        let slot = strip.slotIndex(forLocalX: point.x - strip.frame.minX)
        // A long press on the clipboard chip opens the full history (M9-03).
        if slot >= 0, slot < chipPlan.count, chipPlan[slot]?.source == .clipboardItem {
            stripTouchIgnored = true
            feedback(.action)
            openClipboardPanel()
            return
        }
        // Chips (codes, personal info) and the undo-autocorrect slot are not words in the model.
        guard slot >= 0, slot < lastStrip.slots.count, chipPlan[slot] == nil,
              !(slot == 0 && coordinator.undoableAutocorrection != nil),
              let menu = SuggestionMenu.menu(for: lastStrip.slots[slot], at: slot) else { return }
        suggestionMenu = menu
        feedback(.action)
        renderStrip()
    }

    private func closeSuggestionMenu() {
        suggestionMenu = nil
        renderStrip()
    }

    private func performSuggestionMenu(_ action: SuggestionMenu.Action) {
        guard let menu = suggestionMenu, let host else { closeSuggestionMenu(); return }
        suggestionMenu = nil
        switch action {
        case .forget:
            let word = menu.word
            Task { await host.learner.forgetSuggestion(word); await host.engine?.refreshPersonal() }
            sharedSnapshotDirty = true
        case .neverCorrect:
            let word = menu.word
            Task { await host.store.addNeverCorrect(word); await host.engine?.refreshPersonal() }
            sharedSnapshotDirty = true
        case .cancel: break
        }
        if action != .cancel { feedback(.action) }
        renderStrip()
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
        // Back to the letters, which the emoji search uses.
        if layoutKind != .letters { layoutKind = .letters; lastLayoutKey = nil; relayoutIfNeeded() }
        grid.clearHighlights()
        emoji.open(in: view, frame: emojiFrame, interfaceStyle: grid.appearance == .dark ? .dark : .light)
        view.bringSubviewToFront(strip)
    }

    private func emojiChanged() {
        grid.keysHidden = emoji.keysHidden
        // The search key reads as disabled until there is something to search for.
        grid.setReturnKeyEnabled(emoji.mode == .search ? emoji.hasQuery : input.isReturnKeyEnabled)
        renderStrip()
        // The search results row makes the strip (and the keyboard) taller. Deferred a turn: this can run inside the
        // input machine's own callback (backspace in an empty search field), where touching `machine` would be an
        // exclusivity violation.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.relayoutIfNeeded()
            self.strip.searchRowExtra = self.emoji.searchRowHeight
            self.renderStrip()
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        emoji.didReceiveMemoryWarning()
        // Clipboard history is reloaded from disk on demand; drop the in-memory copy unless the panel shows it.
        if !clipboardPanel.isOpen, !clipboardReading { clipboard = ClipboardHistory(); clipboardLoaded = false }
        grid.trail.clear()
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
        let duo = displayClass
        return LayoutTraits(
            displayClass: duo,
            // A keyboard is always wider than tall, so view bounds can't tell. iPhone landscape has a compact height
            // class; on the Duo displays the screen shape decides (D-20, no device names).
            orientation: duo != .phone ? DisplayMetrics.orientation(screenSize: screenSize ?? view.bounds.size)
                : (traitCollection.verticalSizeClass == .compact ? .landscape : .portrait),
            keyboardKind: KeyboardKind(proxy.keyboardType ?? .default),
            returnKey: ReturnKeyKind(proxy.returnKeyType ?? .default),
            needsInputModeSwitchKey: needsInputModeSwitchKey
        )
    }

    private func refreshAppearanceAndTraits() {
        let appearance: ThemeAppearance
        switch textDocumentProxy.keyboardAppearance ?? .default {
        case .dark: appearance = .dark
        case .light: appearance = .light
        default: appearance = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
        applyTheme(appearance: appearance)
        relayoutIfNeeded()
    }

    /// Resolves the selected theme under Reduce Transparency / Increase Contrast / Bold Text (M8-05) and hands the
    /// result to the grid, the strip and the backdrop. Cheap no-op when nothing changed.
    private func applyTheme(appearance: ThemeAppearance) {
        let skin = KeyboardSkin(
            theme: theme, appearance: appearance,
            accessibility: ThemeAccessibilitySettings(
                reduceTransparency: UIAccessibility.isReduceTransparencyEnabled,
                increaseContrast: UIAccessibility.isDarkerSystemColorsEnabled,
                boldText: UIAccessibility.isBoldTextEnabled))
        // Photos only come from the pre-sized files the app wrote, picked by orientation.
        let photo = skin.backdrop.photoToken.flatMap {
            themeStore.photoURL(token: $0, orientation: currentTraits().orientation == .landscape ? .landscape : .portrait)
        }
        guard skin != appliedSkin || photo != appliedBackdropPhoto else { return }
        appliedSkin = skin
        appliedBackdropPhoto = photo
        grid.skin = skin
        strip.skin = skin
        clipboardPanel.updateSkin(skin)
        backdropView.apply(skin.backdrop, photoURL: photo, displayScale: traitCollection.displayScale > 0 ? traitCollection.displayScale : 3)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        machine?.cancelAll { _ in }
        swipeCapture.cancel()
        resetArbiter()
        grid.trail.clear()
        coordinator.keyboardWillDisappear()
        selectionUI = .none
        emoji.close()
        closeClipboardPanel()
        settleOnDisappear()
        grid.clearHighlights()
        updateRepeatTimer()
        chipTimer?.invalidate()
        chipTimer = nil
    }

    /// The screen the keyboard is on, in its current orientation (rotates with the interface). Display metrics only.
    private var screenSize: CGSize? {
        guard let window = view.window else { return nil }
        let size = window.screen.bounds.size
        return size.width > 0 && size.height > 0 ? size : nil
    }

    /// Phone / Duo outer / Duo inner from screen metrics (`DisplayMetrics`); `.phone` until the view is in a window.
    private var displayClass: DisplayClass {
        #if DEBUG
        // Simulator aid: pretend to be a Duo display on a phone simulator (extension defaults `iBoard.debug.displayClass`).
        if let raw = UserDefaults.standard.string(forKey: "iBoard.debug.displayClass"), let c = DisplayClass(rawValue: raw) { return c }
        #endif
        guard let size = screenSize else { return .phone }
        return DisplayMetrics.displayClass(screenSize: size)
    }

    private var heightKey: String {
        let t = currentTraits()
        return HeightKey.make(displayClass: t.displayClass.rawValue, orientation: t.orientation.rawValue)
    }

    private let duoLocal = DuoLocalStore()

    /// Layout settings from the app (App Group) overridden by what the user did in the keyboard (F11, F1).
    private func currentLayoutSettings() -> LayoutSettings {
        let traits = currentTraits()
        // Display-class defaults (Duo inner: number row in portrait, split in landscape), then the app's values.
        var ls = LayoutSettings.defaults(for: traits)
        ls.numberRow = settings.numberRow || ls.numberRow
        ls.emojiKey = true
        ls.compact = true
        ls.punctuationKeys = settings.punctuationKeys
        ls.searchRowHeight = emoji.stripExtraHeight
        // The height is chosen in the app (Settings > Keyboard height); there is no drag handle any more.
        ls.heightScale = CGFloat(settings.heightScale(forKey: heightKey))
        if traits.displayClass == .duoInner {
            // F12: the pinch (extension-local) wins, then what the app saved explicitly, then the D-20 default.
            let blob = UserDefaults(suiteName: SettingsStore.appGroup)?.data(forKey: SettingsStore.key)
            ls.splitPortrait = DuoSplitPolicy.resolve(
                local: duoLocal.split(for: .portrait),
                app: DuoSplitPolicy.explicitAppValue(blob: blob, key: "duoSplitPortrait"), fallback: ls.splitPortrait)
            ls.splitLandscape = DuoSplitPolicy.resolve(
                local: duoLocal.split(for: .landscape),
                app: DuoSplitPolicy.explicitAppValue(blob: blob, key: "duoSplitLandscape"), fallback: ls.splitLandscape)
            ls.fillToFold = false // the fill-to-fold snap lived on the removed drag handle
        }
        return ls
    }

    /// Spread = split, pinch together = merged (like the iPad keyboard); remembered per orientation, extension-local.
    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard g.state == .ended else { return }
        let traits = currentTraits()
        guard traits.displayClass == .duoInner, layoutKind == .letters, !emoji.isOpen,
              let on = DuoSplitPolicy.decision(forPinchScale: g.scale) else { return }
        // The two fingers were on keys: drop any half-made key press / swipe without inserting.
        machine?.cancelAll { _ in }
        swipeCapture.cancel()
        resetArbiter()
        grid.trail.clear()
        grid.clearHighlights()
        duoLocal.setSplit(on, for: traits.orientation)
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
        applyTheme(appearance: grid.appearance) // photo file follows the orientation

        var want = LayoutEngine.preferredHeight(width: size.width, safeArea: safe, traits: traits, kind: layoutKind, settings: ls)
        if ls.fillToFold, layoutKind == .letters, let screen = screenSize {
            // Preferred height does not apply in the laptop pose: the host uses the fold height.
            want = DuoGeometry.fillToFoldHeight(innerLandscapeHeight: min(screen.width, screen.height))
        }
        if abs((heightConstraint?.constant ?? 0) - want) > 0.5 { heightConstraint?.constant = want }
        let layout = LayoutEngine.layout(containerSize: size, safeArea: safe, traits: traits, kind: layoutKind, settings: ls)
        grid.apply(layout: layout)
        strip.frame = layout.stripFrame
        // Duo split: the strip's three slots stay out of the fold band (container -> strip-local coordinates).
        strip.segments = layout.stripSegments.count == 2
            ? layout.stripSegments.map { $0.offsetBy(dx: -layout.stripFrame.minX, dy: 0) } : []
        emoji.updateFrame(emojiFrame)
        clipboardPanel.updateFrame(emojiFrame)
        coordinator.setLayout(layout)
        startEngineLoad(layout: layout)
        if machine == nil {
            machine = KeyboardInputMachine(layout: layout)
            machine!.longPressDelay = settings.longPressDelay.seconds
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
            // A second finger on the strip while a backspace swipe is deleting words must not insert a suggestion.
            if case .deleteWords = dragMode { stripTouchIgnored = true } else { stripTouchIgnored = false }
            stripTouchStart = point
            scheduleStripHold(at: point)
            return
        }
        if stripTouchID == id, phase == .moved {
            if hypot(point.x - stripTouchStart.x, point.y - stripTouchStart.y) > SuggestionMenu.moveTolerance { stripHoldTimer?.invalidate() }
            return
        }
        if stripTouchID == id {
            if phase == .ended || phase == .cancelled {
                stripTouchID = nil
                stripHoldTimer?.invalidate()
                if suggestionMenu != nil {
                    if phase == .ended, let i = strip.actionIndex(forLocalX: point.x - strip.frame.minX),
                       let a = SuggestionMenu.Action(rawValue: i) { performSuggestionMenu(a) }
                    else if phase == .cancelled { closeSuggestionMenu() }
                    // A release right after the long-press opened the menu keeps it open.
                    return
                }
                if stripTouchIgnored { stripTouchIgnored = false; return }
                if phase == .ended, strip.frame.contains(point), strip.frame.width > 0 {
                    let slot = strip.slotIndex(forLocalX: point.x - strip.frame.minX)
                    if clipboardPanel.isOpen { return } // the panel has its own Done button
                    if emoji.isOpen {
                        let localX = point.x - strip.frame.minX
                        let field = emoji.stripField
                        let actionW = field?.trailingAction == nil ? 0 : SuggestionStripView.searchActionWidth
                        let wide = field?.wide ?? false
                        let pillRight = strip.bounds.width - actionW
                        let onCancel = actionW > 0 && localX > pillRight
                        let onClear = wide ? (!onCancel && localX > pillRight - SuggestionStripView.searchClearZone && localX <= pillRight)
                                           : (slot == 0 && localX > strip.bounds.width / 3 - SuggestionStripView.searchClearZone)
                        emoji.tapStrip(slot: wide ? 0 : slot, onClear: onClear, onCancel: onCancel)
                        feedback()
                        return
                    }
                    if !coach.isDone, strip.isShowingActions {
                        if let i = strip.actionIndex(forLocalX: point.x - strip.frame.minX) {
                            coach.perform(action: i)
                            CoachStore.save(coach)
                            renderStrip()
                            feedback(.action)
                        }
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
                    } else if slot == 0, coordinator.undoableAutocorrection != nil {
                        coordinator.undoAutocorrection()
                    } else {
                        coordinator.tapSlot(slot)
                    }
                    feedback()
                    scheduleAutoShift()
                }
            }
            return
        }
        // A touch before the first layout (machine not built yet) is ignored instead of crashing on `machine!`.
        guard machine != nil else { return }
        switch phase {
        case .began:
            perfDown = Perf.begin(.touchDownToHighlight)
            coordinator.trackTouch(id: id, at: point)
            machine!.touchDown(id: id, at: point, time: time, emit: sink)
            if let layout = grid.layout, !emoji.isOpen || emoji.mode == .search {
                swipeCapture.begin(id: id, at: point, time: time, layout: layout)
                beginArbiter(id: id, at: point, time: time, layout: layout)
            }
        case .moved:
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
        var thresholds = GestureThresholds()
        thresholds.longPressDelay = settings.longPressDelay.seconds
        arbiter = GestureArbiter(start: start, origin: point, time: time, keyHeight: layout.metrics.keyHeight,
                                 hasAlternates: KeyAlternates.longPressOptions(for: identity) != nil,
                                 shiftArmed: identity == .space && shiftManual && grid.shift == .once,
                                 thresholds: thresholds)
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
        markedDelete.cancel() // a drag that did not end in a release-delete leaves the words alone
        deleteBaseContext = nil
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
        if emoji.mode == .search {
            // Emoji search field: the words go away live in the field (a keyboard cannot select there either).
            if deleteBaseContext == nil { deleteBaseContext = emoji.queryText }
            let base = deleteBaseContext ?? ""
            let plan = BackspaceSwipePlan.plan(before: base, extraDistance: extra)
            if case .deleteWords(let old) = dragMode, old == plan { return }
            dragMode = .deleteWords(plan)
            emoji.setQuery(String(base.dropLast(plan.graphemes)))
            return
        }
        if deleteBaseContext == nil { deleteBaseContext = coordinator.contextBeforeForPreview }
        let plan = BackspaceSwipePlan.plan(before: deleteBaseContext ?? "", extraDistance: extra)
        if case .deleteWords(let old) = dragMode, old == plan { return }
        dragMode = .deleteWords(plan)
        if markedDeleteEnabled, !markedDeleteUnsupported {
            markedDelete.show(plan)
            if markedDelete.isActive { verifyMarkedDeleteSoon() }
        }
        let preview = plan.preview.replacingOccurrences(of: "\n", with: " ")
        strip.emphasizedSlots = [1]
        strip.slotTexts = ["", preview, ""]
    }

    /// The host may ignore marked text: after a run-loop turn check that the marked words are still in the field;
    /// if not they are typed back, the in-field preview is switched off and the release deletes plainly.
    private func verifyMarkedDeleteSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.markedDelete.isActive else { return }
            if !self.markedDelete.verify() { self.markedDeleteUnsupported = true }
        }
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
        // Release-delete with the words already marked in the field: remove them now (before the reset cancels).
        var deletedViaMarks = false
        if g == .backspaceSwipeDelete, markedDelete.isActive { deletedViaMarks = markedDelete.verify() && markedDelete.commit() > 0 }
        let mode = dragMode
        let startIndex = gestureKeyIndex
        let origin = gestureOrigin
        let searchDeleteBase = emoji.mode == .search ? deleteBaseContext : nil
        resetArbiter()
        switch g {
        case .spacebarCursor, .spacebarSelection:
            _ = mode // cursor already moved live; the space key was cancelled
            return true
        case .backspaceSwipeDelete:
            if emoji.mode == .search { feedback(); return true } // already applied live to the query
            if case .deleteWords(let plan) = mode {
                if deletedViaMarks { coordinator.finishPreviewedDelete() } else { coordinator.deleteRun(graphemes: plan.graphemes) }
                feedback()
                scheduleAutoShift()
            }
            return true
        case .backspaceSwipeCancel:
            if let base = searchDeleteBase { emoji.setQuery(base) } // dragged back onto the keys: nothing deleted
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
        if emoji.mode == .search {
            // Gesture typing into the emoji search field: the decoded word becomes the query.
            Task { @MainActor [weak self] in
                guard let self, self.emoji.mode == .search,
                      let word = await self.coordinator.decodeSwipeWords(points: points).first else { return }
                self.emoji.setQuery(word)
                self.feedback()
            }
            return
        }
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
            if text == " ", expandTextReplacementIfAny() {
                feedback(.space)
                scheduleAutoShift()
                break
            }
            coordinator.insert(text)
            feedback(text == " " ? .space : .letter)
            scheduleAutoShift()
        case .deleteBackward:
            clearSelection()
            coordinator.deleteBackward()
            feedback(.delete)
            scheduleAutoShift()
        case .deleteWord:
            let t = ProcessInfo.processInfo.systemUptime
            deleteWordRun = t - lastDeleteWordAt < 0.6 ? deleteWordRun + 1 : 0
            lastDeleteWordAt = t
            feedback(.deleteWord(run: deleteWordRun))
            coordinator.deleteWord()
            scheduleAutoShift()
        case .returnKey:
            clearSelection()
            if coordinator.returnKey() { feedback(); scheduleAutoShift() }
        case .openEmoji:
            // Not inside the machine call that emitted this (openEmoji cancels the machine's touches): next turn.
            feedback(.action)
            DispatchQueue.main.async { [weak self] in self?.openEmoji() }
        case .advanceKeyboard:
            advanceToNextInputMode()
        case .shiftChanged(let state):
            shiftManual = state != .off && !applyingAutoShift
            grid.setShift(state)
            if state == .capsLock { feedback(.lock) }
        case .alternatesBegan(let keyIndex):
            swipeCapture.cancel() // a long press and a swipe are exclusive (F5)
            resetArbiter()
            // Not `machine`: this runs inside a machine call. The grid holds the current layout.
            guard let layout = grid.layout, keyIndex < layout.keys.count else { break }
            let key = layout.keys[keyIndex]
            let options = KeyAlternates.longPressOptions(for: key.identity, uppercase: grid.shift != .off,
                                                         clipboardEntry: hasFullAccess && settings.clipboardHistory) ?? []
            strip.beginAlternates(AlternatesSelection(options: options, stripFrame: layout.stripFrame, originRegion: key.touchRegion))
        case .alternatesMoved(let p):
            strip.move(to: p)
        case .alternatesEnded(let p):
            if let text = strip.end(at: p) {
                if text == KeyAlternates.settingsGlyph { openSettingsPage(); feedback(); break }
                if text == KeyAlternates.clipboardGlyph { openClipboardPanel(); feedback(); break }
                if emoji.mode == .search { _ = emoji.handleKey(insert: text); feedback(); break }
                coordinator.insertDirect(text)
                feedback()
                consumeShiftOnce = true
                scheduleAutoShift()
            }
        case .alternatesCancelled:
            strip.cancelAlternates()
        case .layerChanged(let kind):
            layoutKind = kind
            layerChangePending = true
            coordinator.endWordLiterally()
        }
        if let p = perfUp, !isHighlight(event) { Perf.end(p); perfUp = nil }
    }

    /// Opens the iOS Settings page of iBoard (Keyboards, Full Access). Keyboard extensions have no public way to open a
    /// URL, so this walks the responder chain to the host `UIApplication`, the way keyboards have always opened
    /// Settings. Only ever called with `UIApplication.openSettingsURLString`.
    private func openSettingsPage() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, URL, [UIApplication.OpenExternalURLOptionsKey: Any], ((Bool) -> Void)?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: Open.self)
                open(current, selector, url, [:], nil)
                return
            }
            responder = current.next
        }
    }

    private func isHighlight(_ e: KeyEvent) -> Bool {
        if case .highlight = e { return true }
        return false
    }

    private var hapticGenerators: [HapticKind.Weight: UIImpactFeedbackGenerator] = [:]
    private var deleteWordRun = 0
    private var lastDeleteWordAt: TimeInterval = 0

    /// Key click (needs `ClickInputView`, works without Full Access: P-23) and haptic (Full Access only). Letters, space,
    /// delete, word delete (rising), caps lock and actions each get their own weight.
    private func feedback(_ kind: HapticKind = .letter) {
        if settings.keyClickSound { UIDevice.current.playInputClick() }
        guard hapticsEnabled else { return }
        guard let impact = HapticPlan.impact(for: kind, pack: settings.hapticPack, intensity: settings.hapticIntensity) else { return }
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch impact.weight {
        case .light: style = .light
        case .medium: style = .medium
        case .rigid: style = .rigid
        case .soft: style = .soft
        case .heavy: style = .heavy
        }
        let g = hapticGenerators[impact.weight] ?? UIImpactFeedbackGenerator(style: style)
        hapticGenerators[impact.weight] = g
        g.impactOccurred(intensity: CGFloat(impact.intensity))
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
    func setMarkedText(_ text: String) {
        controller.textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
    }
    func unmarkText() { controller.textDocumentProxy.unmarkText() }
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

/// M3-05: the system lexicon entries, already read, as a `SystemLexiconSource`.
private struct FixedLexiconSource: SystemLexiconSource {
    let list: [SystemLexiconEntry]
    func entries() async -> [SystemLexiconEntry] { list }
}
