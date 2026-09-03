import UIKit

/// Centralized haptic feedback service for iPad & Apple Pencil Pro interactions.
/// On supported hardware (Apple Pencil Pro, iPhone/iPad haptic actuators),
/// generates crisp tactical feedback for squeeze, snapping, tool switches, and history steps.
@MainActor
final class HapticFeedbackService {
    static let shared = HapticFeedbackService()

    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let notificationFeedback = UINotificationFeedbackGenerator()

    private init() {
        prepare()
    }

    func prepare() {
        lightImpact.prepare()
        mediumImpact.prepare()
        softImpact.prepare()
        selectionFeedback.prepare()
        notificationFeedback.prepare()
    }

    /// Triggered on Apple Pencil Pro Squeeze gesture.
    func squeeze() {
        mediumImpact.impactOccurred()
    }

    /// Triggered when a shape endpoint locks to a grid intersection or 15-degree angle snap.
    func snapLock() {
        lightImpact.impactOccurred(intensity: 0.85)
    }

    /// Triggered when switching active drawing tools (e.g. via double tap, squeeze, or tool rail).
    func toolSwitched() {
        selectionFeedback.selectionChanged()
    }

    /// Triggered when undoing or redoing an action.
    func undoRedo() {
        softImpact.impactOccurred()
    }

    /// Triggered on successful document or export operations.
    func success() {
        notificationFeedback.notificationOccurred(.success)
    }
}
