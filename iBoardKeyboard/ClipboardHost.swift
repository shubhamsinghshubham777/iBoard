import UIKit
import IBoardTheme
import IBoardUI

/// M9-03: owns the clipboard history panel inside the keyboard. The history itself stays with the controller (it also
/// feeds the strip chip); this host only shows it and reports edits. The panel is built on open and dropped on close
/// (it is cheap: a table of at most 20 rows), so nothing stays resident.
@MainActor
final class ClipboardHost {
    private var panel: ClipboardPanelView?
    var isOpen: Bool { panel != nil }

    /// Paste an item (text) into the host field.
    var onPaste: ((String) -> Void)?
    var onTogglePin: ((UUID, Bool) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onClearAll: (() -> Void)?
    /// The panel closed itself (Done): the controller restores the keys.
    var onClose: (() -> Void)?

    func open(in parent: UIView, frame: CGRect, model: ClipboardPanelModel, skin: KeyboardSkin, style: UIUserInterfaceStyle) {
        guard panel == nil else { return }
        let p = ClipboardPanelView(model: model, skin: skin)
        p.frame = frame
        p.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        p.overrideUserInterfaceStyle = style
        p.onPaste = { [weak self] in self?.onPaste?($0) }
        p.onTogglePin = { [weak self] in self?.onTogglePin?($0, $1) }
        p.onDelete = { [weak self] in self?.onDelete?($0) }
        p.onClearAll = { [weak self] in self?.onClearAll?() }
        p.onClose = { [weak self] in self?.onClose?() }
        parent.addSubview(p)
        panel = p
        UIAccessibility.post(notification: .screenChanged, argument: p)
    }

    func close() {
        panel?.removeFromSuperview()
        panel = nil
    }

    func update(model: ClipboardPanelModel) { panel?.update(model) }
    func updateFrame(_ frame: CGRect) { panel?.frame = frame }
    func updateSkin(_ skin: KeyboardSkin) { panel?.skin = skin }
}
