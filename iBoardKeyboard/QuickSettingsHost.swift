import UIKit
import IBoardCore
import IBoardTheme
import IBoardUI

/// Owns the Quick Settings panel inside the keyboard. Created when opened and dropped when closed, so nothing stays
/// resident (the panel is a handful of small views).
@MainActor
final class QuickSettingsHost {
    private var panel: QuickSettingsPanelView?
    var isOpen: Bool { panel != nil }

    var onEdit: ((QuickSettingsEdit) -> Void)?
    var onIncognito: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// The panel closed itself (Done): the controller restores the keys.
    var onClose: (() -> Void)?

    func open(in parent: UIView, frame: CGRect, state: QuickSettingsState, skin: KeyboardSkin, style: UIUserInterfaceStyle) {
        guard panel == nil else { return }
        let p = QuickSettingsPanelView(state: state, skin: skin)
        p.frame = frame
        p.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        p.overrideUserInterfaceStyle = style
        p.onEdit = { [weak self] in self?.onEdit?($0) }
        p.onIncognito = { [weak self] in self?.onIncognito?($0) }
        p.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        p.onClose = { [weak self] in self?.onClose?() }
        parent.addSubview(p)
        panel = p
        UIAccessibility.post(notification: .screenChanged, argument: p)
    }

    func close() {
        panel?.removeFromSuperview()
        panel = nil
    }

    func update(state: QuickSettingsState) { panel?.update(state) }
    func updateFrame(_ frame: CGRect) { panel?.frame = frame }
    func updateSkin(_ skin: KeyboardSkin) { panel?.skin = skin }
}
