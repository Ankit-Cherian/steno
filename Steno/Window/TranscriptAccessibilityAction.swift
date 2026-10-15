/// A named action on a dictation for VoiceOver and Full Keyboard Access.
struct TranscriptAccessibilityAction: Identifiable {
    let name: String
    let perform: () -> Void
    /// Fix a Word. The dictation's text answers it by opening the form with a list of its words,
    /// since VoiceOver cannot click a word in the text.
    var startsFixWord = false
    var id: String { name }
}
