import UIKit

/// Small, high-contrast status pill for development builds. It stays above
/// the canvas without competing with the drawing controls.
final class DiagnosticsOverlay: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 0.82)
        layer.cornerRadius = 9
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor

        label.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = UIColor.white.withAlphaComponent(0.92)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)
        ])
        update(text: "Metal  -- fps\nStrokes  0   Samples  0\nState  idle")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func update(text: String) {
        label.text = text
        invalidateIntrinsicContentSize()
    }
}
