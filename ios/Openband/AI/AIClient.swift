import Foundation
import SwiftUI
import UIKit

/// The one way the app talks to a model. It holds which service the user chose, reads the key
/// out of the keychain at the moment of the call, and never writes it anywhere else.
///
/// There is no Openband server in this path. The photo goes from this phone to the provider the
/// user picked, on the user's own account, and the answer comes straight back.
@MainActor
final class AIClient: ObservableObject {
    static let shared = AIClient()

    @AppStorage("ai.vendor") private var vendorRaw = AIVendor.anthropic.rawValue
    @AppStorage("ai.model.anthropic") private var anthropicModel = AIVendor.anthropic.defaultModel
    @AppStorage("ai.model.openai") private var openaiModel = AIVendor.openai.defaultModel
    /// The user has been told what leaves the phone, and said yes — once per provider, because
    /// agreeing to send a photo to one company is not agreeing to send it to another.
    @AppStorage("ai.consented.anthropic") private var consentedAnthropic = false
    @AppStorage("ai.consented.openai") private var consentedOpenAI = false

    @Published private(set) var busy = false

    var vendor: AIVendor {
        get { AIVendor(rawValue: vendorRaw) ?? .anthropic }
        set { vendorRaw = newValue.rawValue; objectWillChange.send() }
    }

    var model: String {
        get { vendor == .anthropic ? anthropicModel : openaiModel }
        set {
            if vendor == .anthropic { anthropicModel = newValue } else { openaiModel = newValue }
            objectWillChange.send()
        }
    }

    var key: String? {
        get { Keychain.get(vendor.keychainAccount) }
        set { Keychain.set(newValue, for: vendor.keychainAccount); objectWillChange.send() }
    }

    var hasKey: Bool { !(key ?? "").isEmpty }

    /// Whether the user has agreed to photos going to the provider now in use.
    var hasConsent: Bool { vendor == .anthropic ? consentedAnthropic : consentedOpenAI }

    func setConsent(_ agreed: Bool) {
        if vendor == .anthropic { consentedAnthropic = agreed } else { consentedOpenAI = agreed }
        objectWillChange.send()
    }

    /// Whether a key exists for a service other than the one in use, so the screen can say so.
    func hasKey(for vendor: AIVendor) -> Bool { !(Keychain.get(vendor.keychainAccount) ?? "").isEmpty }

    private var client: AIProviderClient {
        switch vendor {
        case .anthropic: AnthropicClient()
        case .openai: OpenAIClient()
        }
    }

    /// Runs a vision call and decodes the JSON the prompt asked for.
    func ask<T: Decodable>(_ request: AIRequest, as type: T.Type) async throws -> T {
        guard let key, !key.isEmpty else { throw AIError.noKey }
        busy = true
        defer { busy = false }
        let text: String
        do {
            text = try await client.complete(request, model: model, key: key)
        } catch {
            throw error.asAIError
        }
        guard let data = JSONText.object(in: text) else {
            throw AIError.badResponse(String(text.prefix(120)))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIError.badResponse(String(text.prefix(120)))
        }
    }

    /// A one-sentence call that proves the key and the model name are both good.
    func testKey() async -> String {
        guard hasKey else { return String(localized: "No key yet.") }
        do {
            let reply: KeyTest = try await ask(AIRequest(system: Prompts.keyTestSystem,
                                                         user: Prompts.keyTestUser, images: [], maxTokens: 64),
                                                as: KeyTest.self)
            return reply.ok
                ? String(localized: "Working. \(vendor.name) answered as \(model).")
                : String(localized: "The model answered, but not as asked. Try another model name.")
        } catch {
            return (error as? AIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private struct KeyTest: Decodable { let ok: Bool }
}

// MARK: what the prompts return

/// A meal, as the model read it. Every number is an estimate and the screens say so.
struct MealEstimate: Decodable {
    struct Item: Decodable {
        let name: String
        let portion: String
        let kcal: Int
    }

    /// False when the photo is not food; `note` then says what it is.
    let isFood: Bool
    let title: String
    let items: [Item]
    let kcal: Int
    /// The honest range around `kcal`. A point estimate from a photo is a lie told precisely.
    let kcalLow: Int
    let kcalHigh: Int
    let proteinGrams: Double
    let carbGrams: Double
    let fatGrams: Double
    /// 0–1.
    let confidence: Double
    let note: String
}

/// A body check-in. No diagnosis, no single number pretending to be a measurement.
struct BodyAssessment: Decodable {
    /// False when the photos do not show a person standing for a check-in.
    let isPerson: Bool
    let bodyFatLow: Double
    let bodyFatHigh: Double
    /// Markdown, a few short paragraphs.
    let summary: String
    /// Markdown, the week ahead.
    let plan: String
    let note: String
}
