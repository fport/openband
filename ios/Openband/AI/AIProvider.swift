import Foundation
import UIKit

/// Which model service the user brought a key for. Openband has no server and no key of its
/// own: the phone talks straight to whichever of these the user chose.
enum AIVendor: String, CaseIterable, Identifiable, Sendable {
    case anthropic, openai

    var id: String { rawValue }

    var name: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        }
    }

    /// Where the user gets a key, so the screen can send them there instead of explaining.
    var consoleURL: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai: URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    var keyPrefix: String {
        switch self {
        case .anthropic: "sk-ant-"
        case .openai: "sk-"
        }
    }

    /// A capable vision model, and the one the screen suggests. The field stays editable,
    /// because model names change faster than an app ships — these were current in Nov 2026.
    var defaultModel: String {
        switch self {
        case .anthropic: "claude-sonnet-5-5"
        case .openai: "gpt-6.1-terra"
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .anthropic: ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5"]
        case .openai: ["gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-luna"]
        }
    }

    /// The company the photo actually goes to, for the sheet that asks first.
    var legalName: String {
        switch self {
        case .anthropic: "Anthropic PBC"
        case .openai: "OpenAI, Inc."
        }
    }

    var privacyURL: URL {
        switch self {
        case .anthropic: URL(string: "https://www.anthropic.com/legal/privacy")!
        case .openai: URL(string: "https://openai.com/policies/privacy-policy")!
        }
    }

    var keychainAccount: String { "apiKey.\(rawValue)" }
}

/// What a vision call asks for: a system brief, a question, and the photos to look at.
///
/// Nothing read out of Apple Health may be put in one. Apple's HealthKit terms allow sharing
/// with a third party only when that third party itself provides a health or fitness service,
/// and a general-purpose model API does not — which is a rule the user's consent cannot lift.
/// Every number in a prompt comes from the profile the user typed and from workouts this phone
/// recorded itself.
struct AIRequest {
    var system: String
    var user: String
    var images: [Data]
    var maxTokens = 2_000
}

enum AIError: LocalizedError {
    case noKey
    case unauthorized
    case rateLimited
    case tooLarge
    case offline
    case badResponse(String)
    case refused(String)
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            String(localized: "Add your own API key in Coach › AI key first.")
        case .unauthorized:
            String(localized: "That key was refused. Check it in Coach › AI key.")
        case .rateLimited:
            String(localized: "Your API account is rate limited right now. Try again in a minute.")
        case .tooLarge:
            String(localized: "The photo was too big for the model. Try a smaller or less detailed one.")
        case .offline:
            String(localized: "No connection. The analysis needs the internet, because the model runs on the provider's side.")
        case .badResponse(let detail):
            String(localized: "The model answered in a form Openband couldn't read. \(detail)")
        case .refused(let detail):
            detail.isEmpty
                ? String(localized: "The model declined to answer about that photo.")
                : String(localized: "The model declined: \(detail)")
        case .server(let code, let detail):
            String(localized: "The provider returned an error (\(code)). \(detail)")
        }
    }
}

protocol AIProviderClient {
    /// The model's answer as plain text, which the caller parses as JSON.
    func complete(_ request: AIRequest, model: String, key: String) async throws -> String
}

enum AIImage {
    /// Longest side in pixels. Both providers bill by image area and neither gains accuracy
    /// past roughly this, so the phone pays for the downscale once instead of per request.
    static let maxSide: CGFloat = 1_024
    static let quality: CGFloat = 0.8

    /// JPEG bytes, downscaled and stripped of everything but the pixels. Re-encoding through
    /// `UIImage` drops EXIF, which is how the GPS tag of where the photo was taken stays home.
    static func prepare(_ image: UIImage) -> Data? {
        let side = max(image.size.width, image.size.height)
        let scale = side > maxSide ? maxSide / side : 1
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}

extension Error {
    /// Network failures arrive as `URLError`; everything else keeps its own message.
    var asAIError: AIError {
        if let error = self as? AIError { return error }
        if let urlError = self as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut:
                return .offline
            default:
                return .server(urlError.errorCode, urlError.localizedDescription)
            }
        }
        return .badResponse(localizedDescription)
    }
}

/// Pulls the first JSON object out of a model's answer. Models like to wrap JSON in a fenced
/// block or a sentence of preamble; this takes the braces and leaves the chat.
enum JSONText {
    static func object(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let c = text[index]
            if escaped {
                escaped = false
            } else if c == "\\", inString {
                escaped = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start ... index]).data(using: .utf8) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
