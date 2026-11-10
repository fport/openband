import SwiftUI

/// Settings › Apple Health: what goes out, what comes in.
struct AppleHealthView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var health = AppleHealth.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                Text("Everything stays on this phone: Openband and Apple Health trade records directly.")
                    .textStyle(.body)
                    .foregroundStyle(.textBody)
                    .fixedSize(horizontal: false, vertical: true)
                ListCard {
                    // Two requests, not one: asking for both at once means the second switch shows
                    // no sheet at all, and saving is the only one whose answer Health will tell us.
                    toggle(String(localized: "Save band data to Health"),
                           String(localized: "Steps, distance, active energy, heart rate, blood oxygen and sleep after every sync."),
                           isOn: $health.writeEnabled, request: { await health.requestWriteAccess() })
                    toggle(String(localized: "Fill gaps with iPhone steps"),
                           String(localized: "Minutes the band has nothing for, e.g. when it's off your wrist, use the steps your iPhone counted."),
                           isOn: $health.readEnabled, request: { await health.requestReadAccess() }, last: true)
                }
                if let status = health.status {
                    Footnote(status)
                }
                if health.needsHealthApp {
                    // There is no deep link into an app's own Health permissions; the Health app
                    // itself is as close as it gets.
                    Button(String(localized: "Open Health")) {
                        if let url = URL(string: "x-apple-health://") { openURL(url) }
                    }
                    .buttonStyle(.fbTertiary)
                }
                if health.readEnabled {
                    Button(String(localized: "Fill gaps now")) { Task { await model.fillGapsFromHealth() } }
                        .buttonStyle(.fbTertiary)
                }
                if !AppleHealth.isAvailable {
                    Footnote(String(localized: "Apple Health isn't available on this device."))
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.vertical, FBSpace.m)
        }
        .fbScreen()
        .navigationTitle(String(localized: "Apple Health"))
        .navigationBarTitleDisplayMode(.inline)
        // Health permissions change in Settings without telling the app, so the switch is checked
        // again every time this screen appears.
        .onAppear { health.refreshWriteAccess() }
    }

    private func toggle(_ title: String, _ detail: String, isOn: Binding<Bool>,
                        request: @escaping () async -> Bool, last: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: FBSpace.xxs) {
            Toggle(isOn: Binding(get: { isOn.wrappedValue }, set: { on in
                if on {
                    Task {
                        if await request() { isOn.wrappedValue = true }
                    }
                } else {
                    isOn.wrappedValue = false
                }
            })) {
                Text(title).textStyle(.body).foregroundStyle(.textPrimary)
            }
            Text(detail)
                .textStyle(.subhead)
                .foregroundStyle(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, FBSpace.m)
        .padding(.vertical, FBSpace.s)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(.hairline).frame(height: FBStroke.hairline).padding(.leading, FBSpace.m) }
        }
    }
}
