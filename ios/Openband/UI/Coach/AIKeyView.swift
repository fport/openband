import SwiftUI

/// Where the user puts their own API key. Nothing here is Openband's: the account, the key and
/// the bill are the user's, and the screen says exactly what leaves the phone before it does.
struct AIKeyView: View {
    @StateObject private var ai = AIClient.shared
    @State private var draft = ""
    @State private var model = ""
    @State private var result: String?
    @State private var testing = false
    @FocusState private var editing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                explain
                vendorPicker
                keyField
                modelField
                test
                if ai.hasKey { forget }
            Footnote(String(localized: "Coach estimates; it does not measure. Nothing it says is medical advice, and nothing it says is written to Apple Health."))
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.top, FBSpace.xs)
            .padding(.bottom, FBSpace.xl)
        }
        .fbScreen()
        .navigationTitle(String(localized: "AI key"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model = ai.model }
    }

    private var explain: some View {
        Card {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                Text("Your key, your account")
                    .textStyle(.headline)
                    .foregroundStyle(.textPrimary)
                Text("Openband has no AI account and no server of its own. When you scan a meal or take a body check-in, the photo goes from this phone straight to \(ai.vendor.name), signed with the key below, and the answer comes straight back. Openband never sees either.")
                    .textStyle(.body)
                    .foregroundStyle(.textBody)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The key lives in this phone's keychain, not in a backup and not in iCloud. The provider's own terms apply to what you send them.")
                    .textStyle(.subhead)
                    .foregroundStyle(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(String(localized: "Get a key from \(ai.vendor.name)"), destination: ai.vendor.consoleURL)
                    .textStyle(.button)
                    .foregroundStyle(.action)
                    .padding(.top, FBSpace.xxs)
            }
        }
    }

    private var vendorPicker: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: String(localized: "Provider"))
            SegmentedPicker(String(localized: "Provider"),
                            selection: Binding(get: { ai.vendor }, set: { ai.vendor = $0; model = ai.model; draft = ""; result = nil }),
                            options: AIVendor.allCases) { $0.name }
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: String(localized: "Key"))
            Card {
                VStack(alignment: .leading, spacing: FBSpace.xs) {
                    if ai.hasKey, !editing, draft.isEmpty {
                        HStack(spacing: FBSpace.xs) {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.good)
                                .accessibilityHidden(true)
                            Text("A key is stored for \(ai.vendor.name).")
                                .textStyle(.body)
                                .foregroundStyle(.textBody)
                        }
                        Button(String(localized: "Replace it")) { editing = true }
                            .buttonStyle(.fbTertiary)
                    } else {
                        SecureField(ai.vendor.keyPrefix + "…", text: $draft)
                            .textStyle(.monoS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($editing)
                            .submitLabel(.done)
                            .onSubmit(save)
                        HStack {
                            Spacer()
                            Button(String(localized: "Save key"), action: save)
                                .buttonStyle(.fbSecondary)
                                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: String(localized: "Model"))
            Card {
                VStack(alignment: .leading, spacing: FBSpace.xs) {
                    TextField(ai.vendor.defaultModel, text: $model)
                        .textStyle(.monoS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: model) { _, new in ai.model = new.trimmingCharacters(in: .whitespaces) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: FBSpace.xs) {
                            ForEach(ai.vendor.suggestedModels, id: \.self) { name in
                                Button { model = name } label: {
                                    Chip(text: name, tint: model == name ? .action : .textSecondary,
                                         fill: model == name ? .actionSoft : .raised)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            Footnote(String(localized: "Model names change faster than apps ship, so this field is yours to edit. It must be a model that can see images."))
        }
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            Button(testing ? String(localized: "Checking…") : String(localized: "Test the key")) {
                testing = true
                Task {
                    result = await ai.testKey()
                    testing = false
                }
            }
            .buttonStyle(.fbPrimary)
            .disabled(!ai.hasKey || testing)
            if let result {
                Text(result)
                    .textStyle(.subhead)
                    .foregroundStyle(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var forget: some View {
        FBDestructiveButton(title: String(localized: "Forget this key"),
                            message: String(localized: "Openband deletes it from the keychain. Revoke it at \(ai.vendor.name) too if you no longer want it to work."),
                            fullWidth: true) {
            ai.key = nil
            // Permission to send photos to this provider goes with the key.
            ai.setConsent(false)
            draft = ""
            result = nil
        }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ai.key = trimmed
        draft = ""
        editing = false
        result = nil
    }
}
