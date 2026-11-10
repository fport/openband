import SwiftUI
import WidgetKit

/// Openband's widget extension. It exists for one reason: iOS renders Live Activities and the
/// Dynamic Island out of a widget extension and nowhere else, so the running workout needs a
/// bundle of its own to live in. There are no home-screen widgets yet.
@main
struct OpenbandWidgets: WidgetBundle {
    var body: some Widget {
        WorkoutActivityWidget()
    }
}
