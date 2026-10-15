import CoreGraphics

/// Guest desktop coordinates are top-left based and may be negative.
enum HarmonyGuestDesktop {
    static func primarySize(screens: [CGRect], fallback: CGSize) -> CGSize {
        screens.first(where: { $0.origin == .zero && !$0.isEmpty })?.size ?? fallback
    }

    static func mainCard(screens: [CGRect], cardSizes: [CGSize], previous: Int) -> Int {
        guard let main = screens.first(where: { $0.origin == .zero && !$0.isEmpty }) else { return previous }
        let matches = cardSizes.indices.filter { cardSizes[$0] == main.size }
        return matches.count == 1 ? matches[0] : previous
    }

    static func isPrimaryMenuBar(_ window: CGRect, primarySize: CGSize) -> Bool {
        abs(window.minY) <= 2 && window.height > 0 && window.height <= 30
            && window.minX < primarySize.width && window.maxX > 0
    }

    static func isVisible(_ window: CGRect, primarySize: CGSize, secondary: CGRect) -> Bool {
        guard !window.isNull, !window.isInfinite, !window.isEmpty,
              primarySize.width > 0, primarySize.height > 0 else { return false }
        let primary = CGRect(origin: .zero, size: primarySize)
        return window.intersects(primary) || (!secondary.isEmpty && window.intersects(secondary))
    }

    static func isOnSecondary(_ window: CGRect, primarySize: CGSize, secondary: CGRect) -> Bool {
        guard !secondary.isEmpty else { return false }
        let centre = CGPoint(x: window.midX, y: window.midY)
        if secondary.contains(centre) { return true }
        let primary = CGRect(origin: .zero, size: primarySize)
        if primary.contains(centre) { return false }
        // A window spanning staggered displays can have its centre in the gap.
        func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
        return area(window.intersection(secondary)) > area(window.intersection(primary))
    }
}
