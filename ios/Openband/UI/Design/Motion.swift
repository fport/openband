import SwiftUI

/// v3 motion: every state change is a colour change on one curve; no scale, springs or pulsing.
/// Two exceptions: score arcs trim to their value on first appearance, and numbers roll with
/// `.numericText()`. Under Reduce Motion arcs are drawn at once and numbers swap in place.
enum FBMotion {
    /// `timingCurve(0.5, 0, 0, 0.75, duration: 0.33)`: every state change (colour only).
    static let standard = animation(FBTokenTable.Motion.standard)

    /// The same curve over 0.66 s: arcs trimming to their value on first appearance.
    static let arcReveal = animation(FBTokenTable.Motion.arcReveal)

    /// The arc reveal, or nothing under Reduce Motion.
    static func arcReveal(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : arcReveal }

    /// Runs `body` inside the arc reveal, or without animation under Reduce Motion.
    static func reveal(reduceMotion: Bool, _ body: () -> Void) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, body)
        } else {
            withAnimation(arcReveal, body)
        }
    }

    private static func animation(_ m: FBTokenTable.MotionEntry) -> Animation {
        .timingCurve(m.c0x, m.c0y, m.c1x, m.c1y, duration: m.duration)
    }
}

extension AnyTransition {
    /// Context cards and other conditional content fade; they never slide or scale.
    static var fbFade: AnyTransition { .opacity.animation(FBMotion.standard) }
}

private struct FBNumericTransition: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .identity : .numericText(value: value))
    }
}

extension View {
    /// Animates a state change with the standard curve. Use it for colour changes only.
    func fbStateAnimation<V: Equatable>(_ value: V) -> some View {
        animation(FBMotion.standard, value: value)
    }

    /// Numbers roll to their new value (`.numericText`), or swap in place under Reduce Motion.
    func fbNumericTransition(_ value: Double) -> some View {
        modifier(FBNumericTransition(value: value))
    }
}
