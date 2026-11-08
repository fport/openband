import SwiftUI
import UIKit

// Openband v3 design tokens (docs/design-v3-spec.md section 2). Raw values live in
// design/tokens.json and reach Swift through Tokens.generated.swift; this file gives them
// meaning. Colours resolve per trait collection: light, dark and Increase Contrast.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A dynamic colour that follows dark mode and Increase Contrast.
    convenience init(token: FBTokenTable.ColorEntry) {
        self.init { traits in
            let dark = traits.userInterfaceStyle == .dark
            let high = traits.accessibilityContrast == .high
            switch (dark, high) {
            case (false, false): return UIColor(hex: token.light)
            case (false, true): return UIColor(hex: token.lightContrast)
            case (true, false): return UIColor(hex: token.dark)
            case (true, true): return UIColor(hex: token.darkContrast)
            }
        }
    }
}

/// UIKit access to the tokens (navigation bar appearance, Charts interop, renderers).
enum FBUIColor {
    typealias T = FBTokenTable.Colors
    static let canvas = UIColor(token: T.canvas)
    static let surface = UIColor(token: T.surface)
    static let raised = UIColor(token: T.raised)
    static let hairline = UIColor(token: T.hairline)
    static let hairlineStrong = UIColor(token: T.hairlineStrong)
    static let textPrimary = UIColor(token: T.textPrimary)
    static let textBody = UIColor(token: T.textBody)
    static let textSecondary = UIColor(token: T.textSecondary)
    static let textTertiary = UIColor(token: T.textTertiary)
    static let action = UIColor(token: T.action)
    static let actionPressed = UIColor(token: T.actionPressed)
    static let onAction = UIColor(token: T.onAction)
    static let destructive = UIColor(token: T.destructive)
    static let good = UIColor(token: T.good)
    static let fair = UIColor(token: T.fair)
    static let low = UIColor(token: T.low)
    static let sleep = UIColor(token: T.sleep)
    static let activity = UIColor(token: T.activity)
    static let heart = UIColor(token: T.heart)
    static let stageDeep = UIColor(token: T.stageDeep)
    static let stageLight = UIColor(token: T.stageLight)
    static let stageRem = UIColor(token: T.stageRem)
    static let stageAwake = UIColor(token: T.stageAwake)
    static let zone1 = UIColor(token: T.zone1)
    static let zone2 = UIColor(token: T.zone2)
    static let zone3 = UIColor(token: T.zone3)
    static let zone4 = UIColor(token: T.zone4)
    static let zone5 = UIColor(token: T.zone5)
    static let bandStrap = UIColor(token: T.bandStrap)
    static let bandBody = UIColor(token: T.bandBody)
    static let bandFramePro = UIColor(token: T.bandFramePro)
    static let bandScreen = UIColor(token: T.bandScreen)
    static let bandScreenText = UIColor(token: T.bandScreenText)
    static let bandScreenDim = UIColor(token: T.bandScreenDim)
}

// `ShapeStyle where Self == Color` statics give both `.foregroundStyle(.textSecondary)` and
// `Color.textSecondary`.
extension ShapeStyle where Self == Color {
    // Surfaces
    /// Screen background.
    static var canvas: Color { Color(uiColor: FBUIColor.canvas) }
    /// Cards, quick-action circles, segment track.
    static var surface: Color { Color(uiColor: FBUIColor.surface) }
    /// Sheets, selected segment, pressed row.
    static var raised: Color { Color(uiColor: FBUIColor.raised) }
    /// Decorative separators only.
    static var hairline: Color { Color(uiColor: FBUIColor.hairline) }
    /// Arc and slider tracks, chart baselines.
    static var hairlineStrong: Color { Color(uiColor: FBUIColor.hairlineStrong) }

    // Text
    static var textPrimary: Color { Color(uiColor: FBUIColor.textPrimary) }
    static var textBody: Color { Color(uiColor: FBUIColor.textBody) }
    /// Axes, captions, units, status line.
    static var textSecondary: Color { Color(uiColor: FBUIColor.textSecondary) }
    /// Placeholder and disabled only: it fails 4.5:1 on purpose.
    static var textTertiary: Color { Color(uiColor: FBUIColor.textTertiary) }

    // Action: primary buttons and on-state toggles only. Never text, never data.
    static var action: Color { Color(uiColor: FBUIColor.action) }
    static var actionPressed: Color { Color(uiColor: FBUIColor.actionPressed) }
    static var onAction: Color { Color(uiColor: FBUIColor.onAction) }
    /// Destructive button labels.
    static var destructive: Color { Color(uiColor: FBUIColor.destructive) }

    // Data: arcs and deep-dive charts, always paired with a word, position or gap.
    static var good: Color { Color(uiColor: FBUIColor.good) }
    static var fair: Color { Color(uiColor: FBUIColor.fair) }
    static var low: Color { Color(uiColor: FBUIColor.low) }
    static var sleep: Color { Color(uiColor: FBUIColor.sleep) }
    /// Strain and steps.
    static var activity: Color { Color(uiColor: FBUIColor.activity) }
    static var heart: Color { Color(uiColor: FBUIColor.heart) }

    // Hypnogram stages
    static var stageDeep: Color { Color(uiColor: FBUIColor.stageDeep) }
    static var stageLight: Color { Color(uiColor: FBUIColor.stageLight) }
    static var stageRem: Color { Color(uiColor: FBUIColor.stageRem) }
    static var stageAwake: Color { Color(uiColor: FBUIColor.stageAwake) }

    // Heart-rate zones, a single-hue ramp from surface to heart.
    static var zone1: Color { Color(uiColor: FBUIColor.zone1) }
    static var zone2: Color { Color(uiColor: FBUIColor.zone2) }
    static var zone3: Color { Color(uiColor: FBUIColor.zone3) }
    static var zone4: Color { Color(uiColor: FBUIColor.zone4) }
    static var zone5: Color { Color(uiColor: FBUIColor.zone5) }
}

extension Color {
    /// HR zone colour for zones 1 to 5 (clamped).
    static func zone(_ index: Int) -> Color {
        switch index {
        case ...1: return .zone1
        case 2: return .zone2
        case 3: return .zone3
        case 4: return .zone4
        default: return .zone5
        }
    }
}

// MARK: Spacing, radius, stroke, sizes

/// Spacing on a 4/8 grid: 4, 8, 16, 24, 32, 48.
enum FBSpace {
    static let xxs = FBTokenTable.Space.xxs
    static let xs = FBTokenTable.Space.xs
    static let s = FBTokenTable.Space.s
    static let m = FBTokenTable.Space.m
    static let l = FBTokenTable.Space.l
    static let xl = FBTokenTable.Space.xl
    /// Screen side margin.
    static let gutter = FBTokenTable.Space.gutter
    static let cardPadding = FBTokenTable.Space.cardPadding
    /// Between sections of a screen.
    static let section = FBTokenTable.Space.section
}

/// Corner radii. No pills: full circles only for quick actions, the close button and status dots.
enum FBRadius {
    /// Charts, bars, dividers.
    static let chart = FBTokenTable.Radius.chart
    /// Buttons, fields, segments, day chips.
    static let control = FBTokenTable.Radius.control
    /// Cards, list cards, context cards, sheet top corners.
    static let card = FBTokenTable.Radius.card
}

enum FBStroke {
    static let hairline = FBTokenTable.Stroke.hairline
    static let track = FBTokenTable.Stroke.track
    static let notch = FBTokenTable.Stroke.notch
    static let arcHome = FBTokenTable.Stroke.arcHome
    static let arcDetail = FBTokenTable.Stroke.arcDetail
    static let chartLine = FBTokenTable.Stroke.chartLine
    static let sparkline = FBTokenTable.Stroke.sparkline
    static let sliderTrack = FBTokenTable.Stroke.sliderTrack
    static let contributorBar = FBTokenTable.Stroke.contributorBar
    static let zoneBar = FBTokenTable.Stroke.zoneBar
    /// Surface gap between touching marks.
    static let gap = FBTokenTable.Stroke.gap
}

typealias FBSize = FBTokenTable.Size

// MARK: Score bands

/// The three scores. Sleep and Recovery are 0–100 with good/fair/low bands; Strain is 0–21 and
/// only ever gets a word, never a good or bad colour.
enum ScoreKind: String, CaseIterable, Identifiable, Sendable {
    case sleep, recovery, strain

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sleep: String(localized: "Sleep", comment: "Score name")
        case .recovery: String(localized: "Recovery", comment: "Score name")
        case .strain: String(localized: "Strain", comment: "Score name")
        }
    }

    var maximum: Double {
        switch self {
        case .sleep: FBTokenTable.Bands.Sleep.max
        case .recovery: FBTokenTable.Bands.Recovery.max
        case .strain: FBTokenTable.Bands.Strain.max
        }
    }

    /// Where the arc track gets a notch.
    var thresholds: [Double] {
        switch self {
        case .sleep: [FBTokenTable.Bands.Sleep.fair, FBTokenTable.Bands.Sleep.good]
        case .recovery: [FBTokenTable.Bands.Recovery.fair, FBTokenTable.Bands.Recovery.good]
        case .strain: [FBTokenTable.Bands.Strain.moderate, FBTokenTable.Bands.Strain.high, FBTokenTable.Bands.Strain.allOut]
        }
    }

    func band(for value: Double) -> ScoreBand {
        switch self {
        case .sleep: .sleep(value)
        case .recovery: .recovery(value)
        case .strain: .strain(value)
        }
    }

    /// "82", "54", "11.2": Strain keeps one decimal.
    func format(_ value: Double, locale: Locale = .current) -> String {
        switch self {
        case .strain: value.formatted(.number.precision(.fractionLength(1)).locale(locale))
        default: value.formatted(.number.precision(.fractionLength(0)).locale(locale))
        }
    }

    /// Colour of the arc: the band colour, or activity for Strain.
    func color(for value: Double) -> Color { band(for: value).color }
}

/// A score's band: a word plus a colour. The word always travels with the colour.
enum ScoreBand: String, CaseIterable, Sendable {
    case good, fair, low
    case light, moderate, high, allOut

    /// Recovery: 67–100 good, 34–66 fair, 0–33 low.
    static func recovery(_ value: Double) -> ScoreBand {
        value >= FBTokenTable.Bands.Recovery.good ? .good : value >= FBTokenTable.Bands.Recovery.fair ? .fair : .low
    }

    /// Sleep: 80–100 good, 60–79 fair, 0–59 low.
    static func sleep(_ value: Double) -> ScoreBand {
        value >= FBTokenTable.Bands.Sleep.good ? .good : value >= FBTokenTable.Bands.Sleep.fair ? .fair : .low
    }

    /// Strain words: Light 0–9.9, Moderate 10–13.9, High 14–17.9, All out 18–21.
    static func strain(_ value: Double) -> ScoreBand {
        if value >= FBTokenTable.Bands.Strain.allOut { return .allOut }
        if value >= FBTokenTable.Bands.Strain.high { return .high }
        if value >= FBTokenTable.Bands.Strain.moderate { return .moderate }
        return .light
    }

    var word: String {
        switch self {
        case .good: String(localized: "Good", comment: "Score band word")
        case .fair: String(localized: "Fair", comment: "Score band word")
        case .low: String(localized: "Low", comment: "Score band word")
        case .light: String(localized: "Light", comment: "Strain band word")
        case .moderate: String(localized: "Moderate", comment: "Strain band word")
        case .high: String(localized: "High", comment: "Strain band word")
        case .allOut: String(localized: "All out", comment: "Strain band word")
        }
    }

    var color: Color {
        switch self {
        case .good: .good
        case .fair: .fair
        case .low: .low
        case .light, .moderate, .high, .allOut: .activity
        }
    }

    /// Strain words carry no judgement.
    var isJudgement: Bool { [.good, .fair, .low].contains(self) }
}

/// The one word Home leads with, from Recovery's band.
enum DayVerdict: String, CaseIterable, Sendable {
    case ready, steady, rest

    init(recovery: Double) {
        switch ScoreBand.recovery(recovery) {
        case .good: self = .ready
        case .fair: self = .steady
        default: self = .rest
        }
    }

    var word: String {
        switch self {
        case .ready: String(localized: "Ready", comment: "Day verdict")
        case .steady: String(localized: "Steady", comment: "Day verdict")
        case .rest: String(localized: "Rest", comment: "Day verdict")
        }
    }
}
