import UIKit

/// Concept A v4 visual tokens from the upstream Android Drafting Table.
///
/// The Android implementation keeps a warm paper surface, warm near-black
/// ink, a single sienna active-state accent, and an ink-blue secondary accent.
/// Keep these values centralized so UIKit views, menus, thumbnails, and the
/// canvas shell cannot slowly drift apart.  Source: upstream
/// `app/src/main/res/values/colors.xml` at commit 9a668cd and the palette in
/// `MainActivity.kt`.
enum DraftingTheme {
    // MARK: Concept A v4 colors

    static let paper = UIColor(draftingRGB: 0xF5F0E6)       // warm off-white canvas
    static let paperDeep = UIColor(draftingRGB: 0xEDE5D2)   // deeper warm panel surface
    static let ink = UIColor(draftingRGB: 0x2A2620)         // warm near-black ink
    static let inkSoft = UIColor(draftingRGB: 0x6B6357)     // mid warm gray
    static let inkFaint = UIColor(draftingRGB: 0xB8AE9B)    // faint stroke / hint
    static let rule = UIColor(draftingRGB: 0xD9CFB8)        // hairline rule
    static let accent = UIColor(draftingRGB: 0x3A4F6B)      // ink-blue secondary accent
    static let hot = UIColor(draftingRGB: 0xB5482E)         // warm sienna active state
    static let bezel = UIColor(draftingRGB: 0x1A1714)       // outside the canvas
    static let inkDisabled = UIColor(draftingRGB: 0xC8BFA9) // disabled controls

    /// Concept A v4's 4×8 palette, in row-major order.  These are RGB colors
    /// (the Android palette stores no alpha); callers may apply a view alpha
    /// without changing the token itself.
    static let palette: [UIColor] = [
        // Deep hues
        UIColor(draftingRGB: 0x000000), UIColor(draftingRGB: 0x6E2218),
        UIColor(draftingRGB: 0x8A3F0F), UIColor(draftingRGB: 0x886C18),
        UIColor(draftingRGB: 0x3D5E26), UIColor(draftingRGB: 0x195049),
        UIColor(draftingRGB: 0x1A3D60), UIColor(draftingRGB: 0x4A2A65),
        // Standard chromatics
        UIColor(draftingRGB: 0x1A1A1A), UIColor(draftingRGB: 0xB5482E),
        UIColor(draftingRGB: 0xC77A1F), UIColor(draftingRGB: 0xC8A030),
        UIColor(draftingRGB: 0x5A8C3A), UIColor(draftingRGB: 0x2F7E78),
        UIColor(draftingRGB: 0x2A5D8F), UIColor(draftingRGB: 0x6B3A8A),
        // Mid-light tints
        UIColor(draftingRGB: 0x6E6457), UIColor(draftingRGB: 0xC07A60),
        UIColor(draftingRGB: 0xD0A270), UIColor(draftingRGB: 0xCAB870),
        UIColor(draftingRGB: 0x95B070), UIColor(draftingRGB: 0x6FA59E),
        UIColor(draftingRGB: 0x6F95C0), UIColor(draftingRGB: 0xA088B5),
        // Pale neutrals and tints
        UIColor(draftingRGB: 0xFFFFFF), UIColor(draftingRGB: 0x7A7368),
        UIColor(draftingRGB: 0xA89E8A), UIColor(draftingRGB: 0xD9CFB8),
        UIColor(draftingRGB: 0xF2D89A), UIColor(draftingRGB: 0xF2A48F),
        UIColor(draftingRGB: 0x9DB8D8), UIColor(draftingRGB: 0xC7D2A8),
    ]

    // MARK: Typography

    /// JetBrains Mono is the Android UI's label/measurement face.  It is not
    /// bundled yet on iPad, so prefer the installed font by PostScript name
    /// and fall back to Apple's metrically compatible monospaced face.
    static func mono(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        for name in monoNames(for: weight) {
            if let font = UIFont(name: name, size: size) { return font }
        }
        return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Inter is the Android app's prose/control face.  Keep the same weight
    /// mapping, with the system sans face as a deterministic fallback.
    static func sans(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        for name in sansNames(for: weight) {
            if let font = UIFont(name: name, size: size) { return font }
        }
        return UIFont.systemFont(ofSize: size, weight: weight)
    }

    private static func monoNames(for weight: UIFont.Weight) -> [String] {
        let suffix: String
        switch weight.rawValue {
        case let value where value >= UIFont.Weight.bold.rawValue: suffix = "Bold"
        case let value where value >= UIFont.Weight.semibold.rawValue: suffix = "SemiBold"
        case let value where value <= UIFont.Weight.light.rawValue: suffix = "Light"
        default: suffix = "Regular"
        }
        // Different iOS font providers have shipped both spellings and a
        // space-separated family name; check each without making either one
        // a hard dependency of the app bundle.
        return ["JetBrainsMono-\(suffix)", "JetBrains Mono", "Menlo-\(suffix)", "Menlo"]
    }

    private static func sansNames(for weight: UIFont.Weight) -> [String] {
        let suffix: String
        switch weight.rawValue {
        case let value where value >= UIFont.Weight.bold.rawValue: suffix = "Bold"
        case let value where value >= UIFont.Weight.semibold.rawValue: suffix = "SemiBold"
        case let value where value <= UIFont.Weight.light.rawValue: suffix = "Light"
        default: suffix = "Regular"
        }
        return ["Inter-\(suffix)", "Inter", "HelveticaNeue-\(suffix)", "HelveticaNeue"]
    }
}

private extension UIColor {
    convenience init(draftingRGB rgb: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

/// Central icon lookup.  `dt_*` images are the exact upstream Android
/// 24×24 vectors converted into template SVGs.  A semantic alias and an SF
/// fallback keep the shell usable if an asset is omitted from a development
/// build or an older package is opened.
enum DraftingIcon {
    private static let assetAliases: [String: String] = [
        "menu": "dt_menu", "pen": "dt_pen", "brush": "dt_pen",
        "eraser": "dt_eraser", "bucket": "dt_bucket", "shade": "dt_shade",
        "line": "dt_line", "rect": "dt_rect", "rectangle": "dt_rect",
        "circle": "dt_circle", "ellipse": "dt_ellipse",
        "select": "dt_select", "lasso": "dt_lasso", "layers": "dt_layers",
        "pages": "dt_pages", "color": "dt_color", "reset": "dt_reset_view",
        "reset_view": "dt_reset_view", "undo": "dt_undo", "redo": "dt_redo",
        "eye": "dt_eye", "eye_off": "dt_eye_off", "more": "dt_more",
        "drag": "dt_drag_handle", "drag_handle": "dt_drag_handle",
        "plus": "dt_plus", "plus_vector": "dt_plus_vector",
        "vector_select": "dt_vector_select", "grid": "dt_grid", "snap": "dt_snap",
        "eyedropper": "dt_eyedropper", "docs": "dt_docs",
    ]

    private static let sfFallbacks: [String: String] = [
        "menu": "line.3.horizontal", "pen": "pencil.tip", "brush": "pencil.tip",
        "eraser": "eraser", "bucket": "drop", "shade": "scribble.variable",
        "line": "line.diagonal", "rect": "rectangle", "rectangle": "rectangle",
        "circle": "circle", "ellipse": "oval", "select": "selection.pin.in.out",
        "lasso": "lasso", "layers": "square.3.layers.3d", "pages": "doc.on.doc",
        "color": "paintpalette", "reset": "arrow.counterclockwise",
        "reset_view": "arrow.counterclockwise", "undo": "arrow.uturn.backward",
        "redo": "arrow.uturn.forward", "eye": "eye", "eye_off": "eye.slash",
        "more": "ellipsis", "drag": "line.3.horizontal", "drag_handle": "line.3.horizontal",
        "plus": "plus", "plus_vector": "plus", "vector_select": "point.topleft.down.curvedto.point.bottomright.up",
        "grid": "grid", "snap": "scope", "eyedropper": "eyedropper", "docs": "doc.text",
    ]

    /// Resolve an exact `dt_*` template asset first and use an SF Symbol only
    /// when it is unavailable.  The returned image is always template-rendered
    /// so callers can apply the Concept A ink/hot tint consistently.
    static func image(
        named name: String,
        fallback: String? = nil,
        configuration: UIImage.SymbolConfiguration? = nil
    ) -> UIImage? {
        let key = name.lowercased()
        let assetName = key.hasPrefix("dt_") ? key : (assetAliases[key] ?? "dt_\(key)")
        if let image = UIImage(named: assetName) {
            return image.withRenderingMode(.alwaysTemplate)
        }
        let systemName = fallback ?? sfFallbacks[key]
        guard let systemName else { return nil }
        let image = configuration.flatMap { UIImage(systemName: systemName, withConfiguration: $0) }
            ?? UIImage(systemName: systemName)
        return image?.withRenderingMode(.alwaysTemplate)
    }
}
