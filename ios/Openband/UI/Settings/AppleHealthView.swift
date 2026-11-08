import SwiftUI

/// Settings › Apple Health: what goes out, what comes in.
struct AppleHealthView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var health = AppleHealth.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                Text("Everything stays on this phone: Openband and Apple Health trade records directly.")
                    .textStyle(.body)
                    .foregroundStyle(.textBody)
                    .fixedSize(horizontal: false, vertical: true)
                ListCard {
                    toggle(String(localized: "Save band data to Health"),
                           String(localized: "Steps, distance, active energy, heart rate, blood oxygen and sleep after every sync."),
                           isOn: $health.writeEnabled)
                    toggle(String(localized: "Fill gaps with iPhone steps"),
                           String(localized: "Minutes the band has nothing for, e.g. when it's off your wrist, use the steps your iPhone counted."),
                           isOn: $health.readEnabled, last: true)
                }
                if let status = health.status {
                    Footnote(status)
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
    }

    private func toggle(_ title: String, _ detail: String, isOn: Binding<Bool>, last: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: FBSpace.xxs) {
            Toggle(isOn: Binding(get: { isOn.wrappedValue }, set: { on in
                if on {
                    Task {
                        if await health.requestAccess() { isOn.wrappedValue = true }
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
