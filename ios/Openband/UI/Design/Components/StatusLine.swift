import SwiftUI

/// The band in one grey line: "Band 10 Pro · 82% · Synced 2 min ago". A leading 8pt glyph says
/// the state: filled dot nearby, ring out of range, spinner busy, exclamation for an alert.
/// The band name truncates first; at XXL and up the line wraps instead. Inputs are plain
/// values: the screen maps BandLink's phase and Bluetooth state onto `State`.
struct StatusLine: View {
    enum State: Equatable, Sendable {
        /// Seen nearby, idle.
        case nearby
        /// Not seen right now, idle.
        case outOfRange
        case searching
        case connecting
        case authenticating
        /// Busy without a file count.
        case reading
        case syncing(done: Int, total: Int)
        case live
        /// One sentence, e.g. "Close Mi Fitness and try again".
        case failed(String)
        case bluetoothOff
        case bluetoothUnauthorized
        case bluetoothUnsupported

        var isBusy: Bool {
            switch self {
            case .searching, .connecting, .authenticating, .reading, .syncing: true
            default: false
            }
        }

        var isAlert: Bool {
            switch self {
            case .failed, .bluetoothOff, .bluetoothUnauthorized, .bluetoothUnsupported: true
            default: false
            }
        }
    }

    let name: String
    /// Last known battery percentage.
    let battery: Int?
    let state: State
    let lastSync: Date?
    var showsChevron = false

    /// At or under this the battery itself is an alert.
    static let lowBattery = 10

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .subheadline) private var glyphBox: CGFloat = 16

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let parts = Self.parts(name: name, battery: battery, state: state, lastSync: lastSync, now: timeline.date, locale: locale)
            HStack(alignment: .firstTextBaseline, spacing: FBSpace.xs) {
                glyph
                    .frame(width: glyphBox, height: glyphBox)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4.5 }
                if dynamicTypeSize >= .xxLarge {
                    Text(([parts.name] + parts.rest).joined(separator: " · "))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 0) {
                        Text(parts.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(parts.rest.map { " · " + $0 }.joined())
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .textStyle(.subhead)
            .foregroundStyle(state.isAlert ? Color.textPrimary : Color.textSecondary)
            .frame(minHeight: showsChevron ? FBSize.minTarget : nil)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(([parts.name] + parts.rest).joined(separator: ", "))
            .fbStateAnimation(state)
        }
    }

    @ViewBuilder private var glyph: some View {
        if state.isAlert || (isQuiet && (battery ?? 100) <= Self.lowBattery) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.low)
        } else if state.isBusy {
            ProgressView()
                .controlSize(.mini)
                .tint(.textSecondary)
        } else {
            switch state {
            case .live:
                Circle().fill(.heart).frame(width: FBSize.statusGlyph, height: FBSize.statusGlyph)
            case .outOfRange:
                Circle().stroke(.textSecondary, lineWidth: 1.5)
                    .frame(width: FBSize.statusGlyph - 1, height: FBSize.statusGlyph - 1)
            default:
                Circle().fill(.textPrimary).frame(width: FBSize.statusGlyph, height: FBSize.statusGlyph)
            }
        }
    }

    private var isQuiet: Bool { state == .nearby || state == .outOfRange }

    struct Parts: Equatable {
        let name: String
        let rest: [String]
    }

    /// The words of the line, without the separators. Public so screens and tests can reuse it.
    static func parts(name: String, battery: Int?, state: State, lastSync: Date?, now: Date, locale: Locale = .current) -> Parts {
        let percent = battery.map { $0.percentText(locale: locale) }
        switch state {
        case .bluetoothOff:
            return Parts(name: String(localized: "Bluetooth is off"), rest: [])
        case .bluetoothUnauthorized:
            return Parts(name: String(localized: "Bluetooth access is off"), rest: [String(localized: "Allow it in Settings")])
        case .bluetoothUnsupported:
            return Parts(name: String(localized: "Bluetooth LE is unavailable"), rest: [])
        case .failed(let message):
            return Parts(name: name, rest: [message])
        case .searching:
            return Parts(name: name, rest: [String(localized: "Searching…")])
        case .connecting:
            return Parts(name: name, rest: [String(localized: "Connecting…")])
        case .authenticating:
            return Parts(name: name, rest: [String(localized: "Verifying…")])
        case .reading:
            return Parts(name: name, rest: [String(localized: "Reading…")])
        case .syncing(let done, let total):
            return Parts(name: name, rest: [String(localized: "Syncing \(done) of \(total)", comment: "Files synced so far")])
        case .live:
            return Parts(name: name, rest: [percent, String(localized: "Live heart rate")].compactMap { $0 })
        case .nearby:
            return Parts(name: name, rest: [percent, synced(lastSync, now: now, locale: locale)].compactMap { $0 })
        case .outOfRange:
            return Parts(name: name, rest: [String(localized: "Not nearby"), synced(lastSync, now: now, locale: locale)])
        }
    }

    /// "Synced just now", "Synced 2 min ago", "Synced 3 h ago", "Synced 12 Oct", "Not synced yet".
    static func synced(_ date: Date?, now: Date, locale: Locale = .current) -> String {
        guard let date else { return String(localized: "Not synced yet") }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:
            return String(localized: "Synced just now")
        case ..<3600:
            return String(localized: "Synced \(Int(seconds / 60)) min ago", comment: "Last sync, minutes")
        case ..<86_400:
            return String(localized: "Synced \(Int(seconds / 3600)) h ago", comment: "Last sync, hours")
        default:
            let day = date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
            return String(localized: "Synced \(day)", comment: "Last sync, date")
        }
    }
}

#Preview("StatusLine") {
    FBPreviewMatrix {
        StatusLine(name: "Band 10 Pro", battery: 82, state: .nearby, lastSync: .now.addingTimeInterval(-120), showsChevron: true)
        StatusLine(name: "Band 10 Pro", battery: 82, state: .outOfRange, lastSync: .now.addingTimeInterval(-3 * 3600))
        StatusLine(name: "Band 10 Pro", battery: 82, state: .syncing(done: 4, total: 12), lastSync: nil)
        StatusLine(name: "Band 10 Pro", battery: 8, state: .nearby, lastSync: .now)
        StatusLine(name: "Band 10 Pro", battery: nil, state: .bluetoothOff, lastSync: nil)
    }
}
