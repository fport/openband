import SwiftUI

/// The Robot tab: so101-remote's ESP32 screen on the phone. Live joint angles, jog a joint, play a
/// gesture, step the band's sequence, and STOP on top of it all. The Mac runs
/// `so101-band run --phone` and drives the arm; this only sends what the screen would.
struct RobotView: View {
    @StateObject private var robot = RobotClient()
    @State private var joint = "shoulder_pan"
    @State private var enteringAddress = false

    private static let gestures = ["wave", "dance", "yes", "no", "ready", "rest"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FBSpace.l) {
                    header
                    switch robot.link {
                    case .searching:
                        searching
                    case .needsCode:
                        codeEntry
                    case .failed(let message):
                        failed(message)
                    case .found, .connected:
                        controls
                    }
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.bottom, 120)
            }
            .fbScreen()
            .navigationTitle(String(localized: "Robot"))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if robot.link == .connected {
                    stopBar
                }
            }
        }
        .onAppear { robot.start() }
        .onDisappear { robot.stop() }
    }

    // MARK: states

    private var header: some View {
        HStack(spacing: FBSpace.xs) {
            Circle()
                .fill(robot.link == .connected ? Color.green : Color.textTertiary)
                .frame(width: 8, height: 8)
            Text(robot.macName ?? "SO-101")
                .textStyle(.subhead)
                .foregroundStyle(.textSecondary)
            if let live = robot.state?.live {
                Text(live ? "LIVE" : "DRY RUN")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(live ? Color.low.opacity(0.2) : Color.textTertiary.opacity(0.2), in: Capsule())
                    .foregroundStyle(live ? Color.low : Color.textSecondary)
            }
            Spacer()
        }
        .padding(.top, FBSpace.s)
    }

    private var searching: some View {
        VStack(alignment: .leading, spacing: FBSpace.s) {
            HStack(spacing: FBSpace.s) {
                ProgressView()
                Text("Looking for the Mac…").textStyle(.body).foregroundStyle(.textSecondary)
            }
            Text("On the Mac, run `so101-band run --phone` on the same Wi-Fi. Add `--live` to move the real arm.")
                .textStyle(.subhead)
                .foregroundStyle(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            addressEntry
        }
    }

    private var addressEntry: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            Text("Or type the Mac's address").textStyle(.subhead).foregroundStyle(.textSecondary)
            HStack {
                TextField("192.168.1.20:8765", text: $robot.manualAddress)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(FBSpace.s)
                    .background(.surface, in: RoundedRectangle(cornerRadius: 10))
                Button(String(localized: "Connect")) { robot.retry() }
                    .buttonStyle(.fbTertiary)
            }
        }
    }

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: FBSpace.s) {
            Text("Enter the code the Mac shows").textStyle(.headline).foregroundStyle(.textPrimary)
            Text("so101-band prints it when it starts: \"Code: 123456\".")
                .textStyle(.subhead)
                .foregroundStyle(.textSecondary)
            TextField("123456", text: $robot.code)
                .keyboardType(.numberPad)
                .font(.system(.title2, design: .monospaced))
                .padding(FBSpace.s)
                .background(.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: FBSpace.s) {
            Text(message).textStyle(.body).foregroundStyle(.textPrimary)
            Button(String(localized: "Try again")) { robot.retry() }
                .buttonStyle(.fbTertiary)
            addressEntry
        }
    }

    // MARK: controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: FBSpace.l) {
            status
            joints
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Show"))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: FBSpace.s), count: 3), spacing: FBSpace.s) {
                    ForEach(Self.gestures, id: \.self) { name in
                        Button(name.capitalized) { robot.send(line: "G \(name)") }
                            .buttonStyle(RobotChipStyle(active: robot.state?.gesture == name))
                    }
                }
            }
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Band sequence"))
                HStack(spacing: FBSpace.s) {
                    Button { robot.send(action: "previous") } label: { Label("Previous", systemImage: "backward.fill") }
                        .buttonStyle(RobotChipStyle())
                    Button { robot.send(action: "next") } label: { Label("Next", systemImage: "forward.fill") }
                        .buttonStyle(RobotChipStyle())
                }
                if let sequence = robot.state?.sequence {
                    Footnote(sequence.joined(separator: " → "))
                }
            }
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Speed"))
                Picker("Speed", selection: Binding(get: { robot.state?.speed ?? 3 },
                                                   set: { robot.send(line: "V \($0)") })) {
                    Text("Slow").tag(1)
                    Text("Normal").tag(2)
                    Text("Fast").tag(3)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var status: some View {
        Card {
            VStack(alignment: .leading, spacing: FBSpace.xxs) {
                Text(stateLabel).textStyle(.headline).foregroundStyle(.textPrimary)
                if let message = robot.state?.message, !message.isEmpty {
                    Text(message).textStyle(.subhead).foregroundStyle(.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stateLabel: String {
        switch robot.state?.state {
        case "OFF": return String(localized: "Limp: move it by hand, or tap a gesture")
        case "HOLD": return String(localized: "Holding")
        case "MOVE": return robot.state?.gesture.map { String(localized: "Moving: \($0)") } ?? String(localized: "Moving")
        case "ERR": return String(localized: "Stopped after a fault: tap STOP, then move again")
        default: return String(localized: "Connecting…")
        }
    }

    private var joints: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: String(localized: "Move"))
            ListCard {
                let names = robot.state?.joint_names ?? Array(RobotClient.jointLabels.keys)
                ForEach(Array(names.enumerated()), id: \.element) { i, name in
                    jointRow(name, last: i == names.count - 1)
                }
            }
        }
    }

    private func jointRow(_ name: String, last: Bool) -> some View {
        let value = robot.state?.joints?[name]
        let unit = name == "gripper" ? "%" : "°"
        return HStack(spacing: FBSpace.s) {
            Text(RobotClient.jointLabels[name] ?? name)
                .textStyle(.body)
                .foregroundStyle(.textPrimary)
                .frame(width: 70, alignment: .leading)
            Text(value.map { String(format: "%.0f%@", $0, unit) } ?? "–")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { robot.jog(name, by: -5) } label: { Image(systemName: "minus") }
                .buttonStyle(RobotChipStyle(compact: true))
            Button { robot.jog(name, by: 5) } label: { Image(systemName: "plus") }
                .buttonStyle(RobotChipStyle(compact: true))
        }
        .padding(.horizontal, FBSpace.m)
        .padding(.vertical, FBSpace.xs)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(.hairline).frame(height: FBStroke.hairline).padding(.leading, FBSpace.m) }
        }
    }

    private var stopBar: some View {
        HStack(spacing: FBSpace.s) {
            Button { robot.send(line: "S") } label: {
                Text("STOP").font(.headline.weight(.heavy)).frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .background(Color.low, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
            Button {} label: {
                Text("Hold: limp").font(.subheadline).padding(.vertical, 14).padding(.horizontal, FBSpace.s)
            }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.8).onEnded { _ in robot.send(line: "R") })
            .background(.surface, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.textPrimary)
        }
        .padding(.horizontal, FBSpace.gutter)
        .padding(.vertical, FBSpace.xs)
        .background(.canvas)
    }
}

private struct RobotChipStyle: ButtonStyle {
    var active = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: compact ? nil : .infinity)
            .frame(width: compact ? 44 : nil, height: 44)
            .background(active ? Color.action.opacity(0.25) : Color.surface, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(Color.textPrimary)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
