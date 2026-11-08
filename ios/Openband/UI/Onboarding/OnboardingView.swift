import CoreBluetooth
import SwiftData
import SwiftUI

/// First run, three steps: what Openband is (with the one warning that matters), find the band,
/// pair. Progress is three hairline segments, read as "Step 1 of 3".
struct OnboardingView: View {
    @AppStorage("onboarded") private var onboarded = false
    @EnvironmentObject private var session: AppSession
    @State private var step = 1
    @State private var added: [Band] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressSegments(step: step, total: 3)
                .padding(.horizontal, FBSpace.gutter)
                .padding(.top, FBSpace.s)
            Group {
                switch step {
                case 1: WelcomeStep(next: { step = 2 }, demo: { session.setDemo(true) })
                case 2: FindBandStep { bands in added = bands; step = 3 }
                default: ConnectStep(bands: added) { onboarded = true }
                }
            }
            .transition(.fbFade)
        }
        .animation(FBMotion.standard, value: step)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.canvas)
    }
}

struct ProgressSegments: View {
    let step: Int
    let total: Int

    var body: some View {
        HStack(spacing: FBSpace.xs) {
            ForEach(1...total, id: \.self) { i in
                Rectangle()
                    .fill(i <= step ? Color.textPrimary : Color.hairlineStrong)
                    .frame(height: 2)
            }
        }
        .frame(height: FBSpace.m)
        .fbStateAnimation(step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(step) of \(total)"))
    }
}

private struct StepTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .textStyle(.title)
            .foregroundStyle(.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct WelcomeStep: View {
    let next: () -> Void
    let demo: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.m) {
                BandRender(model: .band10Pro, state: .init(time: Date(), battery: nil),
                           height: dynamicTypeSize.isAccessibilitySize ? 120 : 200)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FBSpace.m)
                    .accessibilityHidden(true)
                StepTitle(text: String(localized: "Your band, only yours."))
                Text("Openband talks to your Huawei Band 6 directly. No account, no Huawei Health: your data stays on this phone.")
                    .textStyle(.body)
                    .foregroundStyle(.textBody)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Openband gives the band a key of its own, made on this phone. You'll need the band's MAC address from Settings › About on the band.")
                    .textStyle(.body)
                    .foregroundStyle(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Card {
                    HStack(alignment: .firstTextBaseline, spacing: FBSpace.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.low)
                            .accessibilityHidden(true)
                        Text("After pairing, Huawei Health loses the band. Nothing is deleted from the band, and you can pair it with Huawei Health again any time.")
                            .textStyle(.body)
                            .foregroundStyle(.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                VStack(alignment: .leading, spacing: FBSpace.xxs) {
                    Button(String(localized: "Try with demo data"), action: demo)
                        .buttonStyle(.fbTertiary)
                    Text("No band at hand? See every screen with 30 days of made-up data. Your real data isn't touched.")
                        .textStyle(.subhead)
                        .foregroundStyle(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.m)
        }
        .fbPinnedPrimary(String(localized: "Get started"), background: .canvas, action: next)
    }
}

/// Onboarding step 2: find the band nearby and type its MAC (CoreBluetooth never shows it).
struct FindBandStep: View {
    var title = String(localized: "Find your band")
    let done: ([Band]) -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var link: BandLink
    @State private var chosen: BandLink.Discovered?
    @State private var mac = ""

    private var validMAC: String? { Band.normalizedMAC(mac) }

    /// The band's name ends with the last three hex digits of its MAC: a typo check.
    private var macMatchesName: Bool {
        guard let chosen, let valid = validMAC else { return false }
        let tail = String(valid.filter(\.isHexDigit).suffix(3))
        return chosen.name.uppercased().hasSuffix(tail)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.m) {
                StepTitle(text: title)
                    .padding(.top, FBSpace.m)
                Text("Turn Bluetooth off on the phone the band is paired with, then wake the band's screen.")
                    .textStyle(.body)
                    .foregroundStyle(.textBody)
                    .fixedSize(horizontal: false, vertical: true)

                if link.discovered.isEmpty {
                    HStack(spacing: FBSpace.s) {
                        ProgressView()
                        Text("Looking for bands…").textStyle(.body).foregroundStyle(.textSecondary)
                    }
                    Text(verbatim: "Bluetooth: \(Self.stateName(link.bluetooth)) · \(link.seenCount) devices nearby")
                        .textStyle(.subhead)
                        .foregroundStyle(.textTertiary)
                } else {
                    ListCard {
                        let bands = link.discovered.sorted { ($0.isHuawei ? 1 : 0, $0.rssi) > ($1.isHuawei ? 1 : 0, $1.rssi) }
                        ForEach(Array(bands.enumerated()), id: \.element.id) { i, band in
                            bandRow(band, last: i == bands.count - 1)
                        }
                    }
                }

                if chosen != nil {
                    VStack(alignment: .leading, spacing: FBSpace.xs) {
                        Text("MAC address").textStyle(.headline).foregroundStyle(.textPrimary)
                        Text("On the band: Settings › About.")
                            .textStyle(.subhead)
                            .foregroundStyle(.textSecondary)
                        TextField("AA:BB:CC:DD:EE:FF", text: $mac)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                            .padding(FBSpace.s)
                            .background(.surface, in: RoundedRectangle(cornerRadius: 10))
                        if validMAC != nil, !macMatchesName, chosen?.isHuawei == true {
                            Text("This doesn't end like the band's name. Check it on the band.")
                                .textStyle(.subhead)
                                .foregroundStyle(.low)
                        }
                    }
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.m)
        }
        .fbPinnedPrimary(String(localized: "Continue"), isEnabled: chosen != nil && validMAC != nil, background: .canvas) {
            guard let chosen, let valid = validMAC,
                  let band = model.addBand(name: chosen.name, mac: valid, peripheralID: chosen.id) else { return }
            link.stopScan()
            done([band])
        }
        .onAppear { link.startScan() }
        .onDisappear { link.stopScan() }
    }

    static func stateName(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "on"
        case .poweredOff: return "off"
        case .unauthorized: return "not allowed"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        default: return "starting"
        }
    }

    private func bandRow(_ band: BandLink.Discovered, last: Bool) -> some View {
        let picked = chosen?.id == band.id
        return Button { chosen = band } label: {
            HStack(spacing: FBSpace.s) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(picked ? Color.action : Color.textSecondary)
                    .accessibilityHidden(true)
                ListRow(title: band.name,
                        subtitle: band.isHuawei ? String(localized: "\(band.rssi) dBm · Huawei") : String(localized: "\(band.rssi) dBm"),
                        accessory: .none, showsDivider: false)
            }
            .padding(.leading, FBSpace.s)
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(.hairline).frame(height: FBStroke.hairline).padding(.leading, FBSpace.s) }
            }
        }
        .buttonStyle(.fbRow)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// Adding a band from Settings: the find step in a form sheet; pairing follows on the Band tab.
struct AddBandSheet: View {
    let done: ([Band]) -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(localized: "Add band"))
            FindBandStep { bands in
                if let band = bands.first { model.pair(band) }
                done(bands)
            }
        }
        .fbSheet(.form)
    }
}

private struct ConnectStep: View {
    let bands: [Band]
    let finish: () -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var link: BandLink
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var tried = false
    @State private var sharingKey = false
    @State private var sharedKey = ""
    @State private var keyRejected = false

    private var band: Band? { bands.first }
    private var succeeded: Bool { tried && link.phase == .done && link.bandID == band?.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.m) {
                BandRender(model: band.map(BandPresentation.model) ?? .band10Pro,
                           state: .init(time: Date(), battery: succeeded ? link.battery : nil),
                           height: dynamicTypeSize.isAccessibilitySize ? 120 : 200)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FBSpace.m)
                    .accessibilityHidden(true)
                StepTitle(text: succeeded ? String(localized: "Paired") : String(localized: "Pair"))
                if succeeded {
                    Text(summary)
                        .textStyle(.headline)
                        .foregroundStyle(.textPrimary)
                    if bands.count > 1 {
                        Text("The other bands connect on their first sync.")
                            .textStyle(.body)
                            .foregroundStyle(.textSecondary)
                    }
                } else {
                    Text("Wake the band's screen and keep it close. Pairing writes a new key to the band; Huawei Health then has to pair again to use it.")
                        .textStyle(.body)
                        .foregroundStyle(.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                    if sharingKey {
                        VStack(alignment: .leading, spacing: FBSpace.xs) {
                            Text("On the Mac, run `openband key` and paste the line here.")
                                .textStyle(.subhead)
                                .foregroundStyle(.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            TextField("openband-key:v1:…", text: $sharedKey, axis: .vertical)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .font(.system(.footnote, design: .monospaced))
                                .padding(FBSpace.s)
                                .background(.surface, in: RoundedRectangle(cornerRadius: 10))
                            if keyRejected {
                                Text("That isn't a line from `openband key`.").textStyle(.subhead).foregroundStyle(.low)
                            }
                        }
                    }
                    if let band, tried || link.phase.isBusy {
                        StatusLine(name: band.shortName, battery: nil, state: BandPresentation.statusState(link, band), lastSync: nil)
                    }
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.m)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: FBSpace.xs) {
                if succeeded {
                    Button(String(localized: "Start"), action: finish).buttonStyle(.fbPrimary)
                } else {
                    if sharingKey {
                        Button(String(localized: "Use this key")) {
                            guard let band else { return }
                            keyRejected = !model.useSharedKey(sharedKey, for: band)
                            if !keyRejected { tried = true }
                        }
                        .buttonStyle(.fbPrimary)
                        .disabled(link.phase.isBusy || band == nil || sharedKey.isEmpty)
                    } else {
                        Button(tried ? String(localized: "Try again") : String(localized: "Pair")) {
                            guard let band else { return }
                            tried = true
                            model.pair(band)
                        }
                        .buttonStyle(.fbPrimary)
                        .disabled(link.phase.isBusy || band == nil)
                        Button(String(localized: "Use my Mac's key")) { sharingKey = true }
                            .buttonStyle(.fbTertiary(fullWidth: true))
                    }
                    Button(String(localized: "Skip for now"), action: finish)
                        .buttonStyle(.fbTertiary(fullWidth: true))
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.vertical, FBSpace.xs)
            .background(.canvas)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let battery = link.battery { parts.append(String(localized: "Battery \(FBFormat.percent(Double(battery) / 100))")) }
        if let stats = link.stats { parts.append(String(localized: "\(FBFormat.number(Int(stats.steps))) steps today")) }
        return parts.isEmpty ? String(localized: "The band answered.") : parts.joined(separator: " · ")
    }
}
