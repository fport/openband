import SwiftData
import SwiftUI

/// Coach: what you ate and what you look like, read by a model the user pays for directly.
/// Openband has no account and no server in this path; the key and the photos are the user's.
struct CoachView: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var ai = AIClient.shared
    @Query(sort: \MealEntry.eatenAt, order: .reverse) private var meals: [MealEntry]
    @Query(sort: \BodyScan.takenAt, order: .reverse) private var scans: [BodyScan]
    @State private var scanningMeal = false
    @State private var scanningBody = false

    private var today: [MealEntry] {
        let day = DayKey.current()
        return meals.filter { $0.day == day }
    }

    var body: some View {
        NavigationStack(path: $router.coachPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: FBSpace.l) {
                    if !ai.hasKey {
                        keyPrompt
                    } else {
                        intake
                    }
                    actions
                    if let scan = scans.first { latestScan(scan) }
                    if !meals.isEmpty { recentMeals }
                    learn
                    disclaimer
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.top, FBSpace.xs)
                .padding(.bottom, FBSpace.xl)
            }
            .fbScreen()
            .navigationTitle(String(localized: "Coach"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.aiKey) {
                        Image(systemName: "key")
                            .accessibilityLabel(Text("AI key"))
                    }
                }
            }
            .routeDestinations()
            .sheet(isPresented: $scanningMeal) { MealScanView() }
            .sheet(isPresented: $scanningBody) { BodyScanView() }
        }
    }

    // MARK: sections

    private var keyPrompt: some View {
        EmptyState(systemImage: "key",
                   title: String(localized: "Bring your own key"),
                   message: String(localized: "Coach reads your photos with Anthropic's or OpenAI's model, on your account. The key is kept in this phone's keychain, and photos go straight to the provider you choose — never to Openband."),
                   actionTitle: String(localized: "Add a key")) { router.coachPath = [.aiKey] }
    }

    private var intake: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: String(localized: "Today"),
                          trailing: today.isEmpty ? nil : String(localized: "\(today.count) meals"))
            Card {
                HStack(spacing: 0) {
                    StatBlock(value: FBFormat.number(today.reduce(0) { $0 + $1.kcal }), unit: "kcal",
                              label: String(localized: "Eaten"))
                    StatBlock(value: FBFormat.number(today.reduce(0.0) { $0 + $1.proteinGrams }), unit: "g",
                              label: String(localized: "Protein"))
                    StatBlock(value: FBFormat.number(today.reduce(0.0) { $0 + $1.carbGrams }), unit: "g",
                              label: String(localized: "Carbs"))
                    StatBlock(value: FBFormat.number(today.reduce(0.0) { $0 + $1.fatGrams }), unit: "g",
                              label: String(localized: "Fat"))
                }
            }
            if let maintenance = Maintenance.estimate() {
                Footnote(String(localized: "Maintenance is roughly \(FBFormat.number(maintenance)) kcal for your height, weight and activity level. Every number here is an estimate."))
            }
        }
    }

    private var actions: some View {
        VStack(spacing: FBSpace.s) {
            Button(String(localized: "Scan a meal")) { scanningMeal = true }
                .buttonStyle(.fbPrimary)
                .disabled(!ai.hasKey)
            Button(String(localized: "Body check-in")) { scanningBody = true }
                .buttonStyle(.fbSecondary(fullWidth: true))
                .disabled(!ai.hasKey)
        }
    }

    private func latestScan(_ scan: BodyScan) -> some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: String(localized: "Body"), trailing: FBFormat.shortDay(scan.takenAt))
            NavigationLink(value: Route.bodyScan(scan.id)) {
                Card {
                    VStack(alignment: .leading, spacing: FBSpace.xs) {
                        HStack(spacing: FBSpace.s) {
                            StatBlock(value: scan.bodyFatText ?? "—", label: String(localized: "Body fat"),
                                      style: .figureS)
                            StatBlock(value: FBFormat.number(scan.weightKg, fraction: 1), unit: "kg",
                                      label: String(localized: "Weight"), style: .figureS)
                        }
                        Text(scan.summary.prefix(160) + (scan.summary.count > 160 ? "…" : ""))
                            .textStyle(.subhead)
                            .foregroundStyle(.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var recentMeals: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: String(localized: "Meals"))
            ListCard {
                ForEach(Array(meals.prefix(6).enumerated()), id: \.element.id) { index, meal in
                    MealRow(meal: meal, showsDivider: index < min(6, meals.count) - 1)
                }
            }
            if meals.count > 6 {
                NavigationLink(value: Route.mealHistory) { Text("All \(meals.count) meals") }
                    .buttonStyle(.fbTertiary)
            }
        }
    }

    /// Reference reading. The one part of Coach that needs no key, and the reason the library
    /// sits behind this tab rather than taking a sixth one.
    private var learn: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: String(localized: "Learn"))
            ListCard {
                ForEach(Array(Knowledge.articles.prefix(3).enumerated()), id: \.element.id) { index, article in
                    NavigationLink(value: Route.article(article.id)) {
                        ArticleRow(article: article, showsDivider: index < 2)
                    }
                    .buttonStyle(.fbRow)
                }
            }
            if Knowledge.articles.count > 3 {
                NavigationLink(value: Route.learn) { Text("All \(Knowledge.articles.count) articles") }
                    .buttonStyle(.fbTertiary)
            }
        }
    }

    private var disclaimer: some View {
        Footnote(String(localized: "Coach estimates; it does not measure, and it is not medical advice. Ask a doctor or a dietitian before changing how you eat or train because of it."))
    }
}

struct MealRow: View {
    let meal: MealEntry
    var showsDivider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: FBSpace.s) {
                Group {
                    if let data = meal.photo, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 16))
                            .foregroundStyle(.textSecondary)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: FBRadius.chart, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(meal.title.isEmpty ? String(localized: "Meal") : meal.title)
                        .textStyle(.body)
                        .foregroundStyle(.textPrimary)
                        .lineLimit(1)
                    Text(FBFormat.time(meal.eatenAt))
                        .textStyle(.caption)
                        .foregroundStyle(.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(FBFormat.number(meal.kcal)) kcal")
                    .textStyle(.figureS)
                    .foregroundStyle(.textPrimary)
            }
            .padding(.horizontal, FBSpace.s)
            .frame(minHeight: FBSize.row)
            if showsDivider {
                Rectangle().fill(Color.hairline).frame(height: FBStroke.hairline)
                    .padding(.leading, FBSpace.s)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MealHistoryView: View {
    @Query(sort: \MealEntry.eatenAt, order: .reverse) private var meals: [MealEntry]
    @Environment(\.modelContext) private var context

    var body: some View {
        ScrollView {
            ListCard {
                ForEach(Array(meals.enumerated()), id: \.element.id) { index, meal in
                    MealRow(meal: meal, showsDivider: index < meals.count - 1)
                        .contextMenu {
                            Button(String(localized: "Delete"), role: .destructive) {
                                context.delete(meal)
                                try? context.save()
                            }
                        }
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.xl)
        }
        .fbScreen()
        .navigationTitle(String(localized: "Meals"))
    }
}

/// Mifflin–St Jeor, which is the formula every calculator on the internet is quietly using.
/// An estimate of an estimate: it is shown with that word attached.
enum Maintenance {
    static func estimate(profile: Profile = .load(), activity: ActivityLevel = .moderate) -> Double? {
        guard let weight = profile.weightKg, let height = profile.heightCm, let age = profile.age else { return nil }
        let base = 10 * weight + 6.25 * height - 5 * Double(age)
        let bmr: Double
        switch profile.sex {
        case .male: bmr = base + 5
        case .female: bmr = base - 161
        case .unknown: bmr = base - 78
        }
        return (bmr * activity.multiplier).rounded()
    }
}
