import SwiftData
import SwiftUI

/// Photograph a plate, get a range. Every number stays editable before it is kept, because a
/// model reading a photo is guessing and the person who ate it is not.
struct MealScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @StateObject private var ai = AIClient.shared
    @State private var photo: UIImage?
    @State private var note = ""
    @State private var estimate: MealEstimate?
    @State private var problem: String?
    @State private var working = false
    @State private var consenting = false
    @State private var kcal = 0
    @State private var protein = 0.0
    @State private var carbs = 0.0
    @State private var fat = 0.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FBSpace.l) {
                    HStack { PhotoWell(label: String(localized: "The plate"), image: $photo) }
                        .frame(maxWidth: 220)
                        .frame(maxWidth: .infinity, alignment: .center)

                    TextField(String(localized: "Anything the photo can't show (optional)"), text: $note, axis: .vertical)
                        .textStyle(.body)
                        .lineLimit(1 ... 3)
                        .padding(FBSpace.s)
                        .fbCardBackground()

                    if let estimate { result(estimate) }
                    if let problem {
                        Text(problem)
                            .textStyle(.subhead)
                            .foregroundStyle(.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if estimate == nil {
                        Button(working ? String(localized: "Reading the photo…") : String(localized: "Estimate")) {
                            if ai.hasConsent { Task { await run() } } else { consenting = true }
                        }
                        .buttonStyle(.fbPrimary)
                        .disabled(photo == nil || working)
                    } else {
                        Button(String(localized: "Save")) { save() }
                            .buttonStyle(.fbPrimary)
                    }
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.top, FBSpace.s)
                .padding(.bottom, FBSpace.xl)
            }
            .fbScreen()
            .navigationTitle(String(localized: "Scan a meal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $consenting) {
            AIConsentSheet(vendor: ai.vendor, what: String(localized: "a photo of your meal")) {
                ai.setConsent(true)
                Task { await run() }
            }
        }
    }

    // MARK: result

    @ViewBuilder private func result(_ estimate: MealEstimate) -> some View {
        if !estimate.isFood {
            EmptyState(systemImage: "questionmark", title: String(localized: "Not a meal"),
                       message: estimate.note.isEmpty ? String(localized: "The model didn't see food in that photo.") : estimate.note)
        } else {
            VStack(alignment: .leading, spacing: FBSpace.s) {
                Text(estimate.title)
                    .textStyle(.title)
                    .foregroundStyle(.textPrimary)

                // The range is the honest number; the single figure is just where it sits.
                Card {
                    VStack(alignment: .leading, spacing: FBSpace.xs) {
                        HStack(alignment: .firstTextBaseline, spacing: FBSpace.xxs) {
                            Text(FBFormat.number(kcal))
                                .textStyle(.figureL)
                                .foregroundStyle(.textPrimary)
                            Text("kcal")
                                .textStyle(.headline)
                                .foregroundStyle(.textSecondary)
                        }
                        Text("Likely between \(FBFormat.number(estimate.kcalLow)) and \(FBFormat.number(estimate.kcalHigh)) kcal.")
                            .textStyle(.subhead)
                            .foregroundStyle(.textSecondary)
                        Stepper(String(localized: "Adjust calories"), value: $kcal, in: 0 ... 5_000, step: 25)
                            .textStyle(.subhead)
                            .tint(.action)
                    }
                }

                Card {
                    HStack(spacing: 0) {
                        StatBlock(value: FBFormat.number(protein), unit: "g", label: String(localized: "Protein"), style: .figureS)
                        StatBlock(value: FBFormat.number(carbs), unit: "g", label: String(localized: "Carbs"), style: .figureS)
                        StatBlock(value: FBFormat.number(fat), unit: "g", label: String(localized: "Fat"), style: .figureS)
                    }
                }

                if !estimate.items.isEmpty {
                    ListCard {
                        ForEach(Array(estimate.items.enumerated()), id: \.offset) { index, item in
                            ListRow(title: item.name, subtitle: item.portion,
                                    value: "\(FBFormat.number(item.kcal)) kcal", accessory: .none,
                                    showsDivider: index < estimate.items.count - 1)
                        }
                    }
                }

                HStack(spacing: FBSpace.xs) {
                    Chip(text: String(localized: "Estimate"), systemImage: "exclamationmark.triangle",
                         tint: .action, fill: .actionSoft)
                    Chip(text: confidenceWord(estimate.confidence))
                }
                if !estimate.note.isEmpty {
                    Footnote(estimate.note)
                }
            }
        }
    }

    /// Confidence as a word. A percentage beside a calorie figure reads as an accuracy claim,
    /// and no photo-based estimate can support one.
    private func confidenceWord(_ value: Double) -> String {
        switch value {
        case ..<0.4: String(localized: "Low confidence")
        case ..<0.75: String(localized: "Medium confidence")
        default: String(localized: "High confidence")
        }
    }

    // MARK: work

    private func run() async {
        guard let photo, let data = AIImage.prepare(photo) else { return }
        working = true
        problem = nil
        defer { working = false }
        let request = AIRequest(system: Prompts.mealSystem,
                                user: Prompts.mealUser(locale: Prompts.locale, context: note),
                                images: [data], maxTokens: 1_500)
        do {
            let answer = try await ai.ask(request, as: MealEstimate.self)
            estimate = answer
            kcal = answer.kcal
            protein = answer.proteinGrams
            carbs = answer.carbGrams
            fat = answer.fatGrams
        } catch {
            problem = (error as? AIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save() {
        guard let estimate, estimate.isFood else { return }
        let meal = MealEntry(title: estimate.title, provider: "\(ai.vendor.rawValue)/\(ai.model)")
        meal.kcal = kcal
        meal.proteinGrams = protein
        meal.carbGrams = carbs
        meal.fatGrams = fat
        meal.confidence = estimate.confidence
        meal.items = estimate.items.map { "\($0.name) · \($0.portion) · \($0.kcal) kcal" }.joined(separator: "\n")
        meal.photo = photo.flatMap { AIImage.prepare($0) }
        context.insert(meal)
        try? context.save()
        dismiss()
    }
}
