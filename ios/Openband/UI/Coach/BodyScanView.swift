import SwiftData
import SwiftUI

/// A body check-in: three photos, the numbers only you know, and what the band already
/// recorded. The photos stay on the phone; only the analysis is kept.
struct BodyScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @StateObject private var ai = AIClient.shared
    @Query(sort: \Workout.start, order: .reverse) private var workouts: [Workout]

    @State private var front: UIImage?
    @State private var side: UIImage?
    @State private var back: UIImage?
    @State private var profile = Profile.load()
    @State private var goal = CoachGoal.lose
    @State private var activity = ActivityLevel.moderate
    @State private var diet = Diet.mixed
    @State private var allergies = ""
    @State private var keepPhotos = false
    @State private var working = false
    @State private var problem: String?
    @State private var consenting = false

    enum Diet: String, CaseIterable, Identifiable {
        case mixed, vegetarian, vegan, pescatarian
        var id: String { rawValue }
        var name: String {
            switch self {
            case .mixed: String(localized: "Mixed", comment: "Diet")
            case .vegetarian: String(localized: "Vegetarian", comment: "Diet")
            case .vegan: String(localized: "Vegan", comment: "Diet")
            case .pescatarian: String(localized: "Pescatarian", comment: "Diet")
            }
        }
    }

    private var ready: Bool {
        front != nil && (profile.age ?? 0) > 0 && (profile.heightCm ?? 0) > 0 && (profile.weightKg ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FBSpace.l) {
                    photos
                    numbers
                    choices
                    privacy
                    if let problem {
                        Text(problem)
                            .textStyle(.subhead)
                            .foregroundStyle(.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(working ? String(localized: "Reading the photos…") : String(localized: "Analyse")) {
                        if ai.hasConsent { Task { await run() } } else { consenting = true }
                    }
                    .buttonStyle(.fbPrimary)
                    .disabled(!ready || working)
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.top, FBSpace.s)
                .padding(.bottom, FBSpace.xl)
            }
            .fbScreen()
            .navigationTitle(String(localized: "Body check-in"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $consenting) {
            AIConsentSheet(vendor: ai.vendor, what: String(localized: "your body check-in photos")) {
                ai.setConsent(true)
                Task { await run() }
            }
        }
    }

    // MARK: sections

    private var photos: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            HStack(spacing: FBSpace.xs) {
                PhotoWell(label: String(localized: "Front"), image: $front)
                PhotoWell(label: String(localized: "Side"), image: $side)
                PhotoWell(label: String(localized: "Back"), image: $back)
            }
            Footnote(String(localized: "Front is enough to start. Same light, same spot and same time of day make two check-ins comparable."))
        }
    }

    private var numbers: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: String(localized: "You"))
            Card {
                VStack(spacing: FBSpace.s) {
                    HStack(spacing: FBSpace.s) {
                        field(String(localized: "Age"), value: Binding(
                            get: { Double(profile.age ?? 0) },
                            set: { profile.age = $0 > 0 ? Int($0) : nil }), fraction: 0)
                        field(String(localized: "Height"), unit: "cm", value: Binding(
                            get: { profile.heightCm ?? 0 }, set: { profile.heightCm = $0 > 0 ? $0 : nil }), fraction: 0)
                        field(String(localized: "Weight"), unit: "kg", value: Binding(
                            get: { profile.weightKg ?? 0 }, set: { profile.weightKg = $0 > 0 ? $0 : nil }), fraction: 1)
                    }
                    SegmentedPicker(String(localized: "Sex"), selection: $profile.sex,
                                    options: Profile.Sex.allCases) { sex in
                        switch sex {
                        case .male: String(localized: "Male")
                        case .female: String(localized: "Female")
                        case .unknown: String(localized: "Not said")
                        }
                    }
                }
            }
        }
    }

    private func field(_ label: String, unit: String? = nil, value: Binding<Double>, fraction: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).textStyle(.caption).foregroundStyle(.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                TextField("—", value: value, format: .number.precision(.fractionLength(fraction)))
                    .textStyle(.figureS)
                    .keyboardType(fraction > 0 ? .decimalPad : .numberPad)
                if let unit {
                    Text(unit).textStyle(.caption).foregroundStyle(.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: FBSpace.m) {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Goal"))
                SegmentedPicker(String(localized: "Goal"), selection: $goal, options: CoachGoal.allCases) { $0.name }
            }
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "How active are you?"))
                SegmentedPicker(String(localized: "Activity"), selection: $activity,
                                options: ActivityLevel.allCases) { $0.name }
            }
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Diet"))
                SegmentedPicker(String(localized: "Diet"), selection: $diet, options: Diet.allCases) { $0.name }
                TextField(String(localized: "Allergies or intolerances (optional)"), text: $allergies)
                    .textStyle(.body)
                    .padding(FBSpace.s)
                    .fbCardBackground()
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            Card {
                VStack(alignment: .leading, spacing: FBSpace.xs) {
                    Text("Before you send them")
                        .textStyle(.headline)
                        .foregroundStyle(.textPrimary)
                    Text("These photos go to \(ai.vendor.name) on your own account, signed with your key. They do not pass through any Openband server. Openband strips the location and the camera details first, and keeps only the written analysis unless you ask it to keep the photos too.")
                        .textStyle(.body)
                        .foregroundStyle(.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(isOn: $keepPhotos) {
                        Text("Keep the photos on this phone, to compare later")
                            .textStyle(.subhead)
                            .foregroundStyle(.textBody)
                    }
                    .tint(.action)
                }
            }
            Footnote(String(localized: "A body-fat figure read off a photo is a rough range, not a measurement, and Openband does not write it to Apple Health. It is not medical advice."))
        }
    }

    // MARK: work

    private func run() async {
        working = true
        problem = nil
        defer { working = false }
        profile.save()

        let images = [front, side, back].compactMap { $0 }.compactMap { AIImage.prepare($0) }
        guard !images.isEmpty else { problem = String(localized: "Add at least a front photo."); return }

        let request = AIRequest(
            system: Prompts.bodySystem,
            user: Prompts.bodyUser(locale: Prompts.locale, sex: profile.sex.rawValue, age: profile.age ?? 0,
                                   heightCm: profile.heightCm ?? 0, weightKg: profile.weightKg ?? 0,
                                   goal: goal.rawValue, activity: activity.rawValue, allergies: allergies,
                                   diet: diet.rawValue, recent: recentSummary),
            images: images, maxTokens: 2_500)
        do {
            let answer = try await ai.ask(request, as: BodyAssessment.self)
            guard answer.isPerson else {
                problem = answer.note.isEmpty
                    ? String(localized: "The model didn't see a progress photo there.")
                    : answer.note
                return
            }
            let scan = BodyScan()
            scan.weightKg = profile.weightKg ?? 0
            scan.heightCm = profile.heightCm ?? 0
            scan.age = profile.age ?? 0
            scan.sex = profile.sex.rawValue
            scan.goal = goal.rawValue
            scan.activity = activity.rawValue
            scan.bodyFatLow = answer.bodyFatLow
            scan.bodyFatHigh = answer.bodyFatHigh
            scan.summary = answer.summary
            scan.plan = answer.plan
            scan.provider = "\(ai.vendor.rawValue)/\(ai.model)"
            if keepPhotos {
                scan.frontPhoto = front.flatMap { AIImage.prepare($0) }
                scan.sidePhoto = side.flatMap { AIImage.prepare($0) }
                scan.backPhoto = back.flatMap { AIImage.prepare($0) }
            }
            context.insert(scan)
            try? context.save()
            dismiss()
        } catch {
            problem = (error as? AIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// One line about the last fortnight, so the plan is about this person and not a template.
    private var recentSummary: String {
        let from = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        // Phone-recorded workouts only. Anything that came out of Apple Health is walled off
        // from every prompt — see the note on `AIRequest`.
        let recent = workouts.filter { $0.start >= from && $0.source == "phone" }
        guard !recent.isEmpty else { return "" }
        let distance = recent.reduce(0) { $0 + $1.distance } / 1_000
        let hours = recent.reduce(0) { $0 + $1.elapsed } / 3_600
        let sports = Set(recent.map(\.sport.name)).sorted().joined(separator: ", ")
        return "\(recent.count) workouts in 14 days, \(String(format: "%.1f", distance)) km, "
            + "\(String(format: "%.1f", hours)) hours, sports: \(sports)."
    }
}

/// One past check-in: what was said, and the plan that came with it.
struct BodyScanDetailView: View {
    let scanID: UUID

    @Query private var scans: [BodyScan]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    init(scanID: UUID) {
        self.scanID = scanID
        _scans = Query(filter: #Predicate<BodyScan> { $0.id == scanID })
    }

    var body: some View {
        ScrollView {
            if let scan = scans.first {
                VStack(alignment: .leading, spacing: FBSpace.l) {
                    Card {
                        HStack(spacing: 0) {
                            StatBlock(value: scan.bodyFatText ?? "—", label: String(localized: "Body fat"))
                            StatBlock(value: FBFormat.number(scan.weightKg, fraction: 1), unit: "kg",
                                      label: String(localized: "Weight"))
                            StatBlock(value: FBFormat.number(scan.age), label: String(localized: "Age"))
                        }
                    }
                    if !scan.summary.isEmpty { section(String(localized: "What the photos show"), scan.summary) }
                    if !scan.plan.isEmpty { section(String(localized: "The week ahead"), scan.plan) }
                    photos(scan)
                    Footnote(String(localized: "Read by \(scan.provider). An estimate, not a measurement, and not medical advice."))
                    FBDestructiveButton(title: String(localized: "Delete check-in"), fullWidth: true) {
                        context.delete(scan)
                        try? context.save()
                        dismiss()
                    }
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.top, FBSpace.xs)
                .padding(.bottom, FBSpace.xl)
            }
        }
        .fbScreen()
        .navigationTitle(scans.first.map { FBFormat.shortDay($0.takenAt) } ?? String(localized: "Check-in"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, _ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: title)
            Card {
                Text(LocalizedStringKey(markdown))
                    .textStyle(.body)
                    .foregroundStyle(.textBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func photos(_ scan: BodyScan) -> some View {
        let images = [scan.frontPhoto, scan.sidePhoto, scan.backPhoto].compactMap { $0 }.compactMap(UIImage.init)
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Photos"))
                HStack(spacing: FBSpace.xs) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .aspectRatio(0.85, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: FBRadius.control, style: .continuous))
                    }
                }
            }
        }
    }
}
