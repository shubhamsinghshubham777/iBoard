#if canImport(UIKit)
import UIKit

/// Overlay drawn over the upper part of the keyboard while a backspace swipe is in progress (M5-03). It mirrors the
/// text before the cursor in the keyboard's own font (host fonts / wrapping cannot be matched) and strikes through
/// the words the release deletes. Not interactive: touches stay with the grid. Inside the keyboard bounds only (P-15).
@MainActor
public final class DeleteCanvasView: UIView {
    private let card = UIView()
    private let textLabel = UILabel()
    private let captionLabel = UILabel()
    public private(set) var model: DeleteCanvasModel?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        accessibilityElementsHidden = true // visual aid for the touch drag; VoiceOver users use the key's own actions
        card.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 0.96) : UIColor(white: 1, alpha: 0.96) }
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        textLabel.numberOfLines = 4
        textLabel.lineBreakMode = .byTruncatingHead
        captionLabel.font = .preferredFont(forTextStyle: .footnote)
        captionLabel.textColor = .secondaryLabel
        captionLabel.adjustsFontForContentSizeCategory = true
        addSubview(card)
        card.addSubview(textLabel)
        card.addSubview(captionLabel)
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows or updates the preview. `animated` is false under Reduce Motion (the card then just appears).
    public func show(_ model: DeleteCanvasModel, animated: Bool) {
        self.model = model
        let body = UIFont.systemFont(ofSize: 20)
        let s = NSMutableAttributedString(string: model.kept, attributes: [.font: body, .foregroundColor: UIColor.secondaryLabel])
        s.append(NSAttributedString(string: model.doomed, attributes: [
            .font: body, .foregroundColor: UIColor.systemRed,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .backgroundColor: UIColor.systemRed.withAlphaComponent(0.14)]))
        textLabel.attributedText = s
        captionLabel.text = model.contextLimited ? model.caption + " (more than shown)" : model.caption
        setNeedsLayout()
        if isHidden {
            isHidden = false
            if animated { alpha = 0; UIView.animate(withDuration: 0.12) { self.alpha = 1 } } else { alpha = 1 }
        }
    }

    public func hide() { isHidden = true; model = nil; textLabel.attributedText = nil }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Upper 60%: the thumb on the bottom-left delete key stays below the card.
        let inset: CGFloat = 8
        let w = bounds.width - 2 * inset
        let h = max(60, bounds.height * 0.6 - inset)
        card.frame = CGRect(x: inset, y: inset, width: w, height: h)
        let pad: CGFloat = 12
        let capH = captionLabel.sizeThatFits(CGSize(width: w - 2 * pad, height: 40)).height
        captionLabel.frame = CGRect(x: pad, y: h - capH - 8, width: w - 2 * pad, height: capH)
        textLabel.frame = CGRect(x: pad, y: 8, width: w - 2 * pad, height: captionLabel.frame.minY - 12)
    }
}
#endif
