import CoreGraphics
import Foundation
import IBoardLayout

// Touch state machine v1 (M1-04). Pure logic: no UIKit, no timers, no clock of its own. The host feeds touch events
// (with a monotonic timestamp in seconds) and calls `tick(now:)` while `nextDeadline` is non-nil. Everything the host
// must do comes back through the `emit` closure as `KeyEvent`s. Nothing here stores or logs typed text beyond the
// single key being emitted; it never reads the document.
//
// Touch path budget (ROADMAP §6): fixed slot storage, no collections that grow, no allocation per event.

public enum ShiftState: Sendable, Equatable {
    case off
    /// One capital, then back to `.off` after the next letter.
    case once
    case capsLock
}

/// What the host should do. `highlight` drives the key cap; the rest drive the text proxy / layer swap.
public enum KeyEvent: Sendable, Equatable {
    case highlight(keyIndex: Int, isOn: Bool)
    /// Text to insert (already cased according to shift).
    case insert(String)
    /// One grapheme.
    case deleteBackward
    /// Delete back through the previous word (`wordDeleteCount(before:)` tells the host how many graphemes).
    case deleteWord
    case returnKey
    /// Globe tap: advance to the next keyboard.
    case advanceKeyboard
    /// Emoji key tap: the host opens the emoji panel.
    case openEmoji
    case shiftChanged(ShiftState)
    /// The active layer changed: the host must build a layout for it and call `setLayout`.
    case layerChanged(LayoutKind)
    /// Long press on a key with alternates: the host shows the alternates row in the strip. The key is released.
    case alternatesBegan(keyIndex: Int)
    /// The finger that started the alternates moved (view coordinates).
    case alternatesMoved(CGPoint)
    /// The finger lifted at this point: the host commits the highlighted alternate (or nothing).
    case alternatesEnded(CGPoint)
    /// The touch was cancelled (or the keyboard hidden): drop the alternates row, insert nothing.
    case alternatesCancelled
}

/// Delete-hold timing (F1: "hold repeats with iOS-like acceleration, chars -> words after ~2 s"). Tunable; the exact
/// native curve was not measured, so these numbers are estimates.
public struct DeleteRepeatPolicy: Sendable, Equatable {
    /// Hold time before the first repeat.
    public var initialDelay: TimeInterval = 0.5
    /// Interval between character deletes for the first `fastAfter` seconds of holding.
    public var charInterval: TimeInterval = 0.1
    /// After this much hold time the character interval shortens.
    public var fastAfter: TimeInterval = 1.0
    public var fastCharInterval: TimeInterval = 0.05
    /// After this much hold time repeats delete whole words.
    public var wordAfter: TimeInterval = 2.0
    public var wordInterval: TimeInterval = 0.25
    /// Max repeats emitted by one `tick` (a late host does not flood the proxy).
    public var maxCatchUp: Int = 3

    public init() {}
}

public struct KeyboardInputMachine: Sendable {
    public static let maxTouches = 6
    /// Two shift taps within this many seconds make caps lock.
    public static let doubleTapShiftWindow: TimeInterval = 0.4
    /// A finger must travel this far (pt) from touch-down before sliding onto a neighbour key retargets the press.
    public static let slideSwitchDistance: CGFloat = 10
    /// A touch that lifts within this many seconds of going down types the key it went DOWN on, wherever it drifted.
    public static let quickTapWindow: TimeInterval = 0.2

    private struct Slot: Sendable {
        var touchID = 0
        var keyIndex = -1
        var order: UInt64 = 0
        var isActive = false
        /// The key's action already ran (on touch-down); touch-up only releases.
        var isCommitted = false
        /// When the long press fires (infinity: this key has no alternates / already fired).
        var longPressAt: TimeInterval = .infinity
        var isAlternates = false
        /// The key and event-time deadline of a long press that fired, so a lift stamped before the deadline (the
        /// tick ran late, the lift was still queued) is undone and handled as the tap it was.
        var firedKey = -1
        var firedDeadline: TimeInterval = .infinity
        /// This touch is on the shift key (see `isShiftHeld`).
        var isShiftKey = false
        /// Where the finger went down; a slide shorter than `slideSwitchDistance` keeps the key it went down on.
        var downPoint = CGPoint.zero
        var downKey = -1
        var downTime: TimeInterval = 0
        /// The layer this touch left when it pressed 123 / ABC / #+=: lifting on another key types it and returns
        /// there (the system keyboard's slide-from-123 gesture).
        var slideFrom: LayoutKind?
    }

    public private(set) var layout: KeyboardLayout
    public private(set) var kind: LayoutKind
    public private(set) var shift: ShiftState
    public var deletePolicy = DeleteRepeatPolicy()
    /// Hold time before alternates appear (F1: 350 ms).
    public var longPressDelay: TimeInterval = 0.45

    /// Learned tap offset (see `TouchBias`). The host loads / saves it; taps that are clearly deliberate teach it.
    public var touchBias = TouchBias()
    /// Number of taps learned since the host last saved (the host saves every so often).
    public private(set) var unsavedBiasSamples = 0
    public mutating func biasSaved() { unsavedBiasSamples = 0 }

    private var slots = [Slot](repeating: Slot(), count: KeyboardInputMachine.maxTouches)
    private var orderCounter: UInt64 = 0
    /// Time of the previous `tick` while a long press was pending. A gap longer than `stallGap` means the host's main
    /// thread was blocked, so touch events (a lift that ends a tap) may still be queued: the long press waits.
    private var lastPulse: TimeInterval?
    public static let stallGap: TimeInterval = 0.12
    public static let stallRecheck: TimeInterval = 0.05
    private var lastShiftTap: TimeInterval = -.infinity

    private var deleteTouchID = -1
    private var deleteStart: TimeInterval = 0
    private var deleteNext: TimeInterval = 0

    public init(layout: KeyboardLayout, shift: ShiftState = .off) {
        self.layout = layout
        self.kind = layout.kind
        self.shift = shift
    }

    /// Time the host should call `tick(now:)` next, or nil when nothing repeats.
    public var nextDeadline: TimeInterval? {
        var d: TimeInterval? = deleteTouchID >= 0 ? deleteNext : nil
        for s in slots where s.isActive && !s.isCommitted && s.longPressAt < .infinity {
            d = min(d ?? .infinity, s.longPressAt)
        }
        return d
    }
    /// A finger is down on the shift key: letters typed meanwhile are capitals (one-handed typing).
    public var isShiftHeld: Bool { slots.contains { $0.isActive && $0.isShiftKey } }
    public var activeTouchCount: Int { slots.reduce(0) { $0 + ($1.isActive ? 1 : 0) } }

    // MARK: Host-driven state

    /// Install a new layout (layer change result, rotation, trait change). Touches that still map to the same key
    /// keep going; others are released silently. The host resets all highlights when it swaps layouts.
    public mutating func setLayout(_ new: KeyboardLayout) {
        let old = layout
        layout = new
        kind = new.kind
        for i in 0..<slots.count where slots[i].isActive {
            let k = slots[i].keyIndex
            let same = k >= 0 && k < old.keys.count && k < new.keys.count && old.keys[k].identity == new.keys[k].identity
            if !same { slots[i].keyIndex = -1; slots[i].isCommitted = true }
        }
    }

    /// Set shift from outside (auto-capitalisation, field change).
    public mutating func setShift(_ state: ShiftState, emit: (KeyEvent) -> Void) {
        guard state != shift else { return }
        shift = state
        emit(.shiftChanged(state))
    }

    // MARK: Touch bias

    /// `point` moved by the learned correction, scaled to the letter keys' size. Only the key choice uses it.
    public func biasedPoint(_ point: CGPoint) -> CGPoint {
        let c = touchBias.correction
        guard c.x != 0 || c.y != 0, let f = layout.keys.first(where: { if case .letter = $0.identity { true } else { false } })?.frame
        else { return point }
        return CGPoint(x: point.x + CGFloat(c.x) * f.width, y: point.y + CGFloat(c.y) * f.height)
    }

    /// A clean quick tap on a letter key teaches the bias: down point relative to the key's centre.
    private mutating func learnTap(slot i: Int, up: CGPoint?, time: TimeInterval) {
        guard let up, slots[i].downKey >= 0, slots[i].downKey < layout.keys.count,
              case .letter = layout.keys[slots[i].downKey].identity,
              time - slots[i].downTime < Self.quickTapWindow,
              hypot(up.x - slots[i].downPoint.x, up.y - slots[i].downPoint.y) < Self.slideSwitchDistance else { return }
        let f = layout.keys[slots[i].downKey].frame
        guard f.width > 0, f.height > 0 else { return }
        touchBias.add(dx: Double((slots[i].downPoint.x - f.midX) / f.width), dy: Double((slots[i].downPoint.y - f.midY) / f.height))
        unsavedBiasSamples += 1
    }

    // MARK: Touches

    public mutating func touchDown(id: Int, at point: CGPoint, time: TimeInterval, emit: (KeyEvent) -> Void) {
        // A repeated id means a missed end event: lift it first so an uncommitted tap is typed, not dropped.
        if slotIndex(for: id) != nil { touchUp(id: id, time: time, emit: emit) }
        guard let hit = layout.hit(at: biasedPoint(point)), let free = slots.firstIndex(where: { !$0.isActive }) else { return }

        // Rollover: earlier touches still held are committed first, in the order they went down, so overlapping
        // fast typing keeps the typed order.
        commitPending(time: time, emit: emit)

        orderCounter &+= 1
        slots[free] = Slot(touchID: id, keyIndex: hit.keyIndex, order: orderCounter, isActive: true, isCommitted: false)
        slots[free].downPoint = point
        slots[free].downKey = hit.keyIndex
        slots[free].downTime = time
        emit(.highlight(keyIndex: hit.keyIndex, isOn: true))
        if KeyAlternates.hasLongPress(layout.keys[hit.keyIndex].identity) {
            slots[free].longPressAt = time + longPressDelay
        }

        switch layout.keys[hit.keyIndex].identity {
        case .shift, .layerSwitch, .delete:
            // Immediate keys act on touch-down like the system keyboard.
            slots[free].isCommitted = true
            perform(identity: layout.keys[hit.keyIndex].identity, slot: free, time: time, emit: emit)
        default:
            break // character / return / globe keys commit on touch-up
        }
    }

    public mutating func touchMoved(id: Int, to point: CGPoint, emit: (KeyEvent) -> Void) {
        guard let i = slotIndex(for: id) else { return }
        if slots[i].isAlternates { emit(.alternatesMoved(point)); return }
        guard !slots[i].isCommitted else { return }
        // Moving to another key restarts the long press only for that key's own alternates.
        let dp = slots[i].downPoint
        guard hypot(point.x - dp.x, point.y - dp.y) >= Self.slideSwitchDistance else { return }
        guard let hit = layout.nearestHit(to: point), hit.keyIndex != slots[i].keyIndex else { return }
        emit(.highlight(keyIndex: slots[i].keyIndex, isOn: false))
        slots[i].keyIndex = hit.keyIndex
        emit(.highlight(keyIndex: hit.keyIndex, isOn: true))
        slots[i].longPressAt = .infinity // sliding to another key ends the long-press candidate
    }

    public mutating func touchUp(id: Int, at point: CGPoint? = nil, time: TimeInterval, emit: (KeyEvent) -> Void) {
        guard let i = slotIndex(for: id) else { return }
        if slots[i].isAlternates {
            slots[i].isAlternates = false
            if time < slots[i].firedDeadline, slots[i].firedKey >= 0 {
                // Lifted before the hold time: a fast tap whose long press fired from a late tick.
                emit(.alternatesCancelled)
                let identity = layout.keys[slots[i].firedKey].identity
                slots[i].firedKey = -1
                perform(identity: identity, slot: i, time: time, emit: emit)
                release(slot: i, emit: emit)
                return
            }
            guard let point else {
                // A lift with no position (a repeated touch id stood in for the missed end): `.zero` would land on the
                // popup's first option (i -> î). Cancel the popup and type the key's own character instead.
                emit(.alternatesCancelled)
                if slots[i].firedKey >= 0 {
                    let identity = layout.keys[slots[i].firedKey].identity
                    slots[i].firedKey = -1
                    perform(identity: identity, slot: i, time: time, emit: emit)
                }
                release(slot: i, emit: emit)
                return
            }
            emit(.alternatesEnded(point))
            release(slot: i, emit: emit)
            return
        }
        if let from = slots[i].slideFrom, let point, let hit = layout.hit(at: point), kind != from {
            let identity = layout.keys[hit.keyIndex].identity
            switch identity {
            case .letter, .symbol, .commaEmoji:
                slots[i].slideFrom = nil
                if let text = identity.insertionText ?? (identity == .commaEmoji ? "," : nil) { emit(.insert(text)) }
                kind = from
                emit(.layerChanged(from))
            default: break
            }
        }
        if !slots[i].isCommitted, slots[i].keyIndex >= 0 {
            // A quick tap that drifted onto a neighbour (fingertip rolling down the key) is the key it went down on.
            if slots[i].downKey >= 0, slots[i].keyIndex != slots[i].downKey, time - slots[i].downTime < Self.quickTapWindow {
                emit(.highlight(keyIndex: slots[i].keyIndex, isOn: false))
                slots[i].keyIndex = slots[i].downKey
            }
            slots[i].isCommitted = true
            if slots[i].keyIndex == slots[i].downKey { learnTap(slot: i, up: point, time: time) }
            let identity = layout.keys[slots[i].keyIndex].identity
            // Highlight off first so the cap releases even if the action swaps the layer.
            emit(.highlight(keyIndex: slots[i].keyIndex, isOn: false))
            slots[i].keyIndex = -1
            perform(identity: identity, slot: i, time: time, emit: emit)
        }
        release(slot: i, emit: emit)
    }

    public mutating func touchCancelled(id: Int, emit: (KeyEvent) -> Void) {
        guard let i = slotIndex(for: id) else { return }
        release(slot: i, emit: emit)
    }

    /// Cancel every touch (keyboard hidden, app backgrounded).
    public mutating func cancelAll(emit: (KeyEvent) -> Void) {
        for i in 0..<slots.count where slots[i].isActive { release(slot: i, emit: emit) }
    }

    /// Run delete repeat. Cheap when nothing repeats.
    public mutating func tick(now: TimeInterval, emit: (KeyEvent) -> Void) {
        let stalled: Bool
        if let last = lastPulse, now - last > Self.stallGap { stalled = true } else { stalled = false }
        var pending = false
        for i in 0..<slots.count where slots[i].isActive && !slots[i].isCommitted && slots[i].longPressAt < .infinity { pending = true }
        lastPulse = pending ? now : nil
        if stalled {
            for i in 0..<slots.count where slots[i].isActive && !slots[i].isCommitted && now >= slots[i].longPressAt {
                slots[i].longPressAt = now + Self.stallRecheck
            }
        }
        for i in 0..<slots.count where slots[i].isActive && !slots[i].isCommitted && now >= slots[i].longPressAt {
            let k = slots[i].keyIndex
            slots[i].firedDeadline = slots[i].longPressAt
            slots[i].longPressAt = .infinity
            guard k >= 0 else { continue }
            slots[i].isCommitted = true
            slots[i].isAlternates = true
            slots[i].firedKey = k
            emit(.highlight(keyIndex: k, isOn: false))
            slots[i].keyIndex = -1
            emit(.alternatesBegan(keyIndex: k))
        }
        guard deleteTouchID >= 0 else { return }
        var n = 0
        while now >= deleteNext && n < deletePolicy.maxCatchUp {
            let held = deleteNext - deleteStart
            if held >= deletePolicy.wordAfter {
                emit(.deleteWord)
                deleteNext += deletePolicy.wordInterval
            } else {
                emit(.deleteBackward)
                deleteNext += held >= deletePolicy.fastAfter ? deletePolicy.fastCharInterval : deletePolicy.charInterval
            }
            n += 1
        }
        if now >= deleteNext { deleteNext = now + deletePolicy.charInterval } // dropped the backlog
    }

    // MARK: Internals

    private func slotIndex(for id: Int) -> Int? {
        for i in 0..<slots.count where slots[i].isActive && slots[i].touchID == id { return i }
        return nil
    }

    private mutating func release(slot i: Int, emit: (KeyEvent) -> Void) {
        if slots[i].keyIndex >= 0 { emit(.highlight(keyIndex: slots[i].keyIndex, isOn: false)) }
        if slots[i].isAlternates { emit(.alternatesCancelled) }
        if deleteTouchID == slots[i].touchID { deleteTouchID = -1 }
        slots[i].isActive = false
        slots[i].isAlternates = false
        slots[i].firedKey = -1
        slots[i].firedDeadline = .infinity
        slots[i].isShiftKey = false
        slots[i].slideFrom = nil
        slots[i].longPressAt = .infinity
        slots[i].keyIndex = -1
    }

    /// Commit every touch that is down but not yet acted on, oldest first. Their finger is still down, so only the
    /// action runs; the cap stays highlighted until the touch ends.
    private mutating func commitPending(time: TimeInterval, emit: (KeyEvent) -> Void) {
        while true {
            var best = -1
            for i in 0..<slots.count where slots[i].isActive && !slots[i].isCommitted {
                if best < 0 || slots[i].order < slots[best].order { best = i }
            }
            guard best >= 0 else { return }
            slots[best].isCommitted = true
            let k = slots[best].keyIndex
            if k >= 0 { perform(identity: layout.keys[k].identity, slot: best, time: time, emit: emit) }
        }
    }

    private mutating func perform(identity: KeyIdentity, slot: Int, time: TimeInterval, emit: (KeyEvent) -> Void) {
        switch identity {
        case .letter(let s):
            // A held shift key capitalises even when the tap toggled auto-capitalisation off, and a letter typed
            // with it is not the first half of a caps-lock double tap.
            let held = isShiftHeld
            if held { lastShiftTap = -.infinity }
            emit(.insert(shift == .off && !held ? s : s.uppercased()))
            if shift == .once { shift = .off; emit(.shiftChanged(.off)) }
        case .symbol(let s), .domainSuffix(let s):
            emit(.insert(s))
        case .space:
            emit(.insert(" "))
        case .returnKey:
            emit(.returnKey)
        case .globe:
            emit(.advanceKeyboard)
        case .emoji:
            emit(.openEmoji)
        case .commaEmoji:
            emit(.insert(",")) // a tap is a comma; the long press (see `tick`) opens the emoji panel
        case .delete:
            emit(.deleteBackward)
            deleteTouchID = slots[slot].touchID
            deleteStart = time
            deleteNext = time + deletePolicy.initialDelay
        case .shift:
            slots[slot].isShiftKey = true
            tapShift(time: time, emit: emit)
        case .layerSwitch(let target):
            guard target != kind else { return }
            // Other fingers keep their cap highlight only until the host swaps layouts; end them now.
            for i in 0..<slots.count where slots[i].isActive && slots[i].keyIndex >= 0 {
                emit(.highlight(keyIndex: slots[i].keyIndex, isOn: false))
                slots[i].keyIndex = -1
                slots[i].isCommitted = true
            }
            slots[slot].slideFrom = kind
            kind = target
            emit(.layerChanged(target))
        }
    }

    private mutating func tapShift(time: TimeInterval, emit: (KeyEvent) -> Void) {
        let next: ShiftState
        if shift != .capsLock, time - lastShiftTap <= Self.doubleTapShiftWindow {
            // Second tap in the window: caps lock, also when the first tap only switched auto-capitalisation off.
            next = .capsLock
            lastShiftTap = -.infinity
        } else {
            switch shift {
            case .off: next = .once
            case .once: next = .off
            case .capsLock: next = .off
            }
            lastShiftTap = shift == .capsLock ? -.infinity : time
        }
        shift = next
        emit(.shiftChanged(next))
    }
}

/// Number of graphemes to delete for a word delete, given the text before the cursor: the trailing whitespace plus
/// the word before it. 0 when `before` is empty. Pure; the host passes `documentContextBeforeInput` (never stored).
public func wordDeleteCount(before: String) -> Int {
    var count = 0
    var inWord = false
    for ch in before.reversed() {
        if ch.isWhitespace || ch.isNewline {
            if inWord { break }
            count += 1
        } else {
            inWord = true
            count += 1
        }
    }
    return count
}
