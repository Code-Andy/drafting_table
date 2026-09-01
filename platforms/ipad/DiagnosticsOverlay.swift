import UIKit

final class DiagnosticsOverlay: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.62)
        layer.cornerRadius = 8
        label.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .white
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
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
