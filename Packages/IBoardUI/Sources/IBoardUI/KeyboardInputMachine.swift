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
    case shiftChanged(ShiftState)
    /// The active layer changed: the host must build a layout for it and call `setLayout`.
    case layerChanged(LayoutKind)
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
    public static let doubleTapShiftWindow: TimeInterval = 0.35

    private struct Slot: Sendable {
        var touchID = 0
        var keyIndex = -1
        var order: UInt64 = 0
        var isActive = false
        /// The key's action already ran (on touch-down); touch-up only releases.
        var isCommitted = false
    }

    public private(set) var layout: KeyboardLayout
    public private(set) var kind: LayoutKind
    public private(set) var shift: ShiftState
    public var deletePolicy = DeleteRepeatPolicy()

    private var slots = [Slot](repeating: Slot(), count: KeyboardInputMachine.maxTouches)
    private var orderCounter: UInt64 = 0
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
    public var nextDeadline: TimeInterval? { deleteTouchID >= 0 ? deleteNext : nil }
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

    // MARK: Touches

    public mutating func touchDown(id: Int, at point: CGPoint, time: TimeInterval, emit: (KeyEvent) -> Void) {
        // A repeated id means a missed end event: treat it as a cancel first.
        if let i = slotIndex(for: id) { release(slot: i, emit: emit) }
        guard let hit = layout.hit(at: point), let free = slots.firstIndex(where: { !$0.isActive }) else { return }

        // Rollover: earlier touches still held are committed first, in the order they went down, so overlapping
        // fast typing keeps the typed order.
        commitPending(time: time, emit: emit)

        orderCounter &+= 1
        slots[free] = Slot(touchID: id, keyIndex: hit.keyIndex, order: orderCounter, isActive: true, isCommitted: false)
        emit(.highlight(keyIndex: hit.keyIndex, isOn: true))

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
        guard let i = slotIndex(for: id), !slots[i].isCommitted else { return }
        guard let hit = layout.nearestHit(to: point), hit.keyIndex != slots[i].keyIndex else { return }
        emit(.highlight(keyIndex: slots[i].keyIndex, isOn: false))
        slots[i].keyIndex = hit.keyIndex
        emit(.highlight(keyIndex: hit.keyIndex, isOn: true))
    }

    public mutating func touchUp(id: Int, time: TimeInterval, emit: (KeyEvent) -> Void) {
        guard let i = slotIndex(for: id) else { return }
        if !slots[i].isCommitted, slots[i].keyIndex >= 0 {
            slots[i].isCommitted = true
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
        if deleteTouchID == slots[i].touchID { deleteTouchID = -1 }
        slots[i].isActive = false
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
            emit(.insert(shift == .off ? s : s.uppercased()))
            if shift == .once { shift = .off; emit(.shiftChanged(.off)) }
        case .symbol(let s), .domainSuffix(let s):
            emit(.insert(s))
        case .space:
            emit(.insert(" "))
        case .returnKey:
            emit(.returnKey)
        case .globe:
            emit(.advanceKeyboard)
        case .delete:
            emit(.deleteBackward)
            deleteTouchID = slots[slot].touchID
            deleteStart = time
            deleteNext = time + deletePolicy.initialDelay
        case .shift:
            tapShift(time: time, emit: emit)
        case .layerSwitch(let target):
            guard target != kind else { return }
            // Other fingers keep their cap highlight only until the host swaps layouts; end them now.
            for i in 0..<slots.count where slots[i].isActive && slots[i].keyIndex >= 0 {
                emit(.highlight(keyIndex: slots[i].keyIndex, isOn: false))
                slots[i].keyIndex = -1
                slots[i].isCommitted = true
            }
            kind = target
            emit(.layerChanged(target))
        }
    }

    private mutating func tapShift(time: TimeInterval, emit: (KeyEvent) -> Void) {
        let next: ShiftState
        switch shift {
        case .off:
            next = .once
            lastShiftTap = time
        case .once:
            next = time - lastShiftTap <= Self.doubleTapShiftWindow ? .capsLock : .off
            lastShiftTap = -.infinity
        case .capsLock:
            next = .off
            lastShiftTap = -.infinity
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
