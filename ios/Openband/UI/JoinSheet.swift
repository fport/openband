import SwiftUI

/// Confirms an invite opened from a QR code before anything is sent to a server.
struct JoinSheet: View {
    let invite: AppModel.Invite
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var tried = false

    private var joined: Bool { tried && model.hubEnabled }
    private var host: String { invite.hub.host ?? invite.hub.absoluteString }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: joined ? String(localized: "You joined") : String(localized: "Join web access"))
            ScrollView {
                VStack(alignment: .leading, spacing: FBSpace.m) {
                    if joined {
                        paragraph(String(localized: "After every sync your data also goes to \(host). Open your panel in a browser; your API key is in Band › Openband settings › Web access."))
                    } else if model.hubEnabled {
                        paragraph(String(localized: "Web access is already on (\(model.hubURL.host ?? "")). To switch servers, turn it off first in Band › Openband settings › Web access."))
                    } else {
                        paragraph(String(localized: "When you join, Openband also sends your data to this server. You can see your panel in a browser and reach your data through the API. Turn it off any time to delete your data there."))
                        Card {
                            VStack(alignment: .leading, spacing: FBSpace.xxs) {
                                Text(verbatim: host)
                                    .textStyle(.headline)
                                    .foregroundStyle(.textPrimary)
                                Text("Invite code \(invite.code)")
                                    .textStyle(.subhead)
                                    .foregroundStyle(.textSecondary)
                            }
                        }
                        if !invite.isDefaultHub {
                            ContextCard.alert(String(localized: "This isn't Openband's default server. Your health data will go there; join only if the invite came from someone you trust."))
                        }
                        if tried, let status = model.hubStatus {
                            ContextCard.alert(status)
                        }
                    }
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.top, FBSpace.xs)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: FBSpace.xs) {
                if joined {
                    Button(String(localized: "Open web panel")) {
                        if let url = model.hub.panelURL() { openURL(url) }
                    }
                    .buttonStyle(.fbPrimary)
                    Button(String(localized: "Close")) { dismiss() }
                        .buttonStyle(.fbTertiary(fullWidth: true))
                } else if model.hubEnabled {
                    Button(String(localized: "Close")) { dismiss() }
                        .buttonStyle(.fbSecondary(fullWidth: true))
                } else {
                    Button {
                        tried = true
                        Task { await model.accept(invite) }
                    } label: {
                        if model.hubBusy { ProgressView().tint(.onAction) } else { Text("Join") }
                    }
                    .buttonStyle(.fbPrimary)
                    .disabled(model.hubBusy)
                    Button(String(localized: "Cancel")) { dismiss() }
                        .buttonStyle(.fbTertiary(fullWidth: true))
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.vertical, FBSpace.xs)
            .background(.raised)
        }
        .fbSheet(.form)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .textStyle(.body)
            .foregroundStyle(.textBody)
            .fixedSize(horizontal: false, vertical: true)
    }
}
