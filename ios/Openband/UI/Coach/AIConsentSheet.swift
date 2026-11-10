import SwiftUI

/// Asked once per provider, before the first photo ever leaves the phone. It names the company,
/// says what goes with the photo, says what does not go at all, and links their policy — because
/// "we send your photos to a third party" is not something to bury in a footnote.
struct AIConsentSheet: View {
    let vendor: AIVendor
    let what: String
    let onAgree: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FBSpace.m) {
                    Text("Your photos go to \(vendor.name)")
                        .textStyle(.title)
                        .foregroundStyle(.textPrimary)
                        .accessibilityAddTraits(.isHeader)

                    paragraph("To read \(what), Openband sends it — with the age, height, weight, goal and activity level you typed in — from this iPhone straight to \(vendor.legalName), using your own API key. Openband has no server and never receives or stores your photos.")
                    paragraph("\(vendor.name) handles it under their terms, as your API customer rather than Openband's. Openband cannot control or delete what they keep.")

                    Card {
                        HStack(alignment: .firstTextBaseline, spacing: FBSpace.xs) {
                            Image(systemName: "heart.text.square")
                                .foregroundStyle(.good)
                                .accessibilityHidden(true)
                            Text("Your Apple Health data is never sent. It stays on this iPhone.")
                                .textStyle(.body)
                                .foregroundStyle(.textBody)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Link(String(localized: "Read \(vendor.name)'s privacy policy"), destination: vendor.privacyURL)
                        .textStyle(.button)
                        .foregroundStyle(.action)

                    paragraph("You can take this back at any time in Coach › AI key.")
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.top, FBSpace.s)
                .padding(.bottom, FBSpace.l)
            }
            .fbScreen()
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: FBSpace.xs) {
                    Button(String(localized: "I agree — send to \(vendor.name)")) {
                        onAgree()
                        dismiss()
                    }
                    .buttonStyle(.fbPrimary)
                    Button(String(localized: "Don't send")) { dismiss() }
                        .buttonStyle(.fbTertiary(fullWidth: true))
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.bottom, FBSpace.xs)
                .background(.canvas)
            }
            .navigationTitle(String(localized: "Before you send"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .textStyle(.body)
            .foregroundStyle(.textBody)
            .fixedSize(horizontal: false, vertical: true)
    }
}
