import Foundation
import LintelCore

/// Settings cleanup: with the Lock Screen page gone, alerts
/// are filtered by Focus only, and VoiceOver reads the island's content in plain words.
func runSettingsChecks() {
    var filters = NotificationFilters()
    check(NotificationGroup.allCases.allSatisfy { filters.allowedWhenFocused.contains($0) && Keys.allowWhenFocused($0).defaultValue },
          "every alert group is allowed during a Focus by default")
    filters.allowedWhenFocused.remove(.sound)
    check(filters.allows(.volume, in: ActivityContext()), "no Focus: nothing is filtered")
    check(!filters.allows(.volume, in: ActivityContext(focusActive: true)) && filters.allows(.brightness, in: ActivityContext(focusActive: true)),
          "Focus: only the switched-off group is filtered")

    // Spoken names: words, never raw values or type descriptions.
    check(CompactPresentation.idle.spokenName == nil, "nothing in the closed island: no name")
    check(CompactPresentation.live([.calendar, .media]).spokenName == "calendar and media", "two activities read as a list")
    check(CompactPresentation.live([.timer, .media, .calendar]).spokenName == "calendar, media and timer", "three activities")
    check(CompactPresentation.notification(.deviceConnected).spokenName == "audio device connected", "alert in words")
    check(ExpandedContent.nothing.spokenName == "date and time" && ExpandedContent.both.spokenName == "media and calendar",
          "open island content in words")
    let names = NotificationKind.allCases.map(\.spokenName) + ExpandedContent.allCases.map(\.spokenName)
        + [CompactPresentation.lock, .peek(.media), .peek(.calendar), .live(Set(LiveActivityKind.allCases))].compactMap(\.spokenName)
    check(names.allSatisfy { !$0.isEmpty && !$0.contains("(") && !$0.contains("LintelCore") && $0.range(of: "[a-z][A-Z]", options: .regularExpression) == nil },
          "no spoken name looks like code")
}
