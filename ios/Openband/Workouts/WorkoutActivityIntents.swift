import AppIntents

// The two buttons on the Lock Screen. A `LiveActivityIntent` runs inside the app's own process
// without bringing it to the front, which is the whole point: the recorder only exists there.
//
// The widget extension compiles this file so its buttons can name the intents, and the app fills
// in the two actions at launch. The extension's copy of them therefore stays empty, which is
// also why neither intent reaches for the recorder, the store or Apple Health directly: none of
// that is in the extension.

/// How the app carries out what the Lock Screen asks for. `AppSession` fills these in.
@MainActor
enum WorkoutActivityActions {
    /// Pause, or start again when already paused.
    static var togglePause: (() -> Void)?
    /// Save the workout and end the activity, the way the live screen's Finish does.
    static var finish: (() async -> Void)?
}

struct PauseWorkoutIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or resume the workout"
    static var description = IntentDescription("Pauses the workout you are recording, or starts it again.")
    /// Nothing to say back: the activity redraws, and that is the answer.
    static var openAppWhenRun = false
    /// Useless on its own in Shortcuts — there is no workout to pause unless one is running.
    static var isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        WorkoutActivityActions.togglePause?()
        return .result()
    }
}

struct FinishWorkoutIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Finish the workout"
    static var description = IntentDescription("Stops the workout you are recording and saves it.")
    static var openAppWhenRun = false
    static var isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await WorkoutActivityActions.finish?()
        return .result()
    }
}
