import AppKit
import StenoKit
import SwiftUI

// MARK: - Text that follows the text-size setting

/// Sets a Grove font that follows the text-size step in the environment, capped at the step
/// the window layouts hold.
private struct GroveFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let scaled = (size * GroveScale.factor(for: dynamicTypeSize) * 2).rounded() / 2
        content.font(.system(size: scaled, weight: weight))
    }
}

enum GroveScale {
    /// The window follows the text size up to Larger; beyond that it would not fit.
    static let maximum: CGFloat = 1.35

    static func factor(for size: DynamicTypeSize) -> CGFloat {
        min(maximum, QuillType.scale(for: size))
    }
}

extension View {
    /// System font at `size`, scaled with the text-size setting.
    func groveFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        modifier(GroveFontModifier(size: size, weight: weight))
    }
}

// MARK: - Keyboard focus

/// The visible focus of one item, drawn only on the focused item. On macOS 14 and later the
/// system container effect is switched off for the Grove window, so this is the only ring; on
/// macOS 13 the system draws the focused control's own ring and this adds nothing.
struct GroveFocusRing: ViewModifier {
    var isFocused: Bool
    var cornerRadius: CGFloat
    /// The ring sits on forest glass, where the accent green all but disappears in light mode
    /// (1.4:1), so it is drawn in mint (5.8:1 or better) instead.
    var onGlass = false
    @Environment(\.groveTheme) private var theme

    func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
                    .strokeBorder(onGlass ? theme.mintColor : theme.accentColor, lineWidth: 2)
                    .padding(-2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    /// Turns off SwiftUI's container focus effect for this window on macOS 14 and later.
    @ViewBuilder
    func groveFocusEffectsOff() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }

    /// Gives native controls their own focus ring back inside a Grove window, on macOS 14 and later.
    @ViewBuilder
    func groveFocusEffectsOn() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled(false)
        } else {
            self
        }
    }

    func groveFocusRing(_ isFocused: Bool, cornerRadius: CGFloat) -> some View {
        modifier(GroveFocusRing(isFocused: isFocused, cornerRadius: cornerRadius))
    }

    /// Draws the Grove ring while this control has the keyboard focus.
    func groveKeyboardFocus(cornerRadius: CGFloat, onGlass: Bool = false) -> some View {
        modifier(GroveKeyboardFocus(cornerRadius: cornerRadius, onGlass: onGlass))
    }
}

/// The ring of a control that has the keyboard focus, from Tab with Full Keyboard Access or from
/// VoiceOver moving the focus. A click does not focus a button, so a click draws no ring.
///
/// The focus is read with `focused(_:)` on the control itself: `isFocused` read inside a button
/// style stays false while its button has the focus, so a style cannot draw the ring.
struct GroveKeyboardFocus: ViewModifier {
    var cornerRadius: CGFloat
    var onGlass = false
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .groveFocusEffectsOff()
            .focused($isFocused)
            .modifier(KeyboardFocusRing(isFocused: isFocused, cornerRadius: cornerRadius, onGlass: onGlass))
    }
}

/// A Grove button look with the keyboard focus ring around it.
struct GroveFocusedButtonStyle<Look: ButtonStyle>: PrimitiveButtonStyle {
    let look: Look
    let cornerRadius: CGFloat
    var onGlass = false

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(look)
            .groveKeyboardFocus(cornerRadius: cornerRadius, onGlass: onGlass)
    }
}

/// A button drawn as its label alone, with the keyboard focus ring around it.
struct GroveQuietButtonStyle: PrimitiveButtonStyle {
    var cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.plain)
            .groveKeyboardFocus(cornerRadius: cornerRadius)
    }
}

extension PrimitiveButtonStyle where Self == GroveQuietButtonStyle {
    static func groveQuiet(cornerRadius: CGFloat = 4) -> GroveQuietButtonStyle {
        GroveQuietButtonStyle(cornerRadius: cornerRadius)
    }
}

/// A direction pressed on the keyboard.
enum GroveMove: Sendable {
    case up, down, left, right
}

/// Whether the keyboard handler of a list has focus, and a way to give it focus when a row is
/// clicked.
@MainActor
final class GroveKeyFocus: ObservableObject {
    @Published fileprivate(set) var isFocused = false
    fileprivate weak var view: GroveKeyView?

    func request() {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }
}

/// Arrow keys, Return, Delete and Copy for a list or a grid, without SwiftUI's container focus.
///
/// An invisible AppKit view takes the keyboard when the list is clicked or tabbed to. It draws
/// no focus ring of its own: the focused row shows the ring, so a whole list never lights up.
struct GroveKeyHandling: NSViewRepresentable {
    @ObservedObject var focus: GroveKeyFocus
    var onMove: (GroveMove) -> Void = { _ in }
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?

    func makeNSView(context: Context) -> GroveKeyView {
        let view = GroveKeyView()
        focus.view = view
        return view
    }

    func updateNSView(_ view: GroveKeyView, context: Context) {
        view.onMove = onMove
        view.onReturn = onReturn
        view.onDelete = onDelete
        view.onCopy = onCopy
        view.onFocusChange = { [weak focus] value in
            Task { @MainActor in focus?.isFocused = value }
        }
    }
}

final class GroveKeyView: NSView, NSUserInterfaceValidations {
    var onMove: (GroveMove) -> Void = { _ in }
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func becomeFirstResponder() -> Bool {
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusChange?(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 126: onMove(.up)
        case 125: onMove(.down)
        case 123: onMove(.left)
        case 124: onMove(.right)
        case 36, 76:
            if let onReturn { onReturn() } else { super.keyDown(with: event) }
        case 51, 117:
            if let onDelete { onDelete() } else { super.keyDown(with: event) }
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return onCopy != nil }
        return false
    }

    // Constant answers, safe on any thread Accessibility asks from.
    nonisolated override func accessibilityRole() -> NSAccessibility.Role? { nil }
    nonisolated override func isAccessibilityElement() -> Bool { false }
}

// MARK: - Drawing

/// The voice quill's colours on one surface: the barbs' gradient and the shaft, nib and line.
struct GroveQuillColors: Equatable {
    var barbLow: NSColor
    var barbHigh: NSColor
    var shaft: NSColor

    /// The quill in its own colours, for brand glass. Under Increase Contrast the barbs are the
    /// lightest of them.
    static func glass(_ theme: GroveTheme) -> GroveQuillColors {
        let colors = BrandMark.Colors.green
        let high = color(colors.barbHigh)
        return GroveQuillColors(barbLow: theme.increaseContrast ? high : color(colors.barbLow), barbHigh: high,
                                shaft: color(colors.shaft))
    }

    /// The quiet quill of an empty state: the ink at 30 % for the barbs, a little more for the
    /// shaft, so it sits below the text it introduces.
    static func quiet(_ theme: GroveTheme) -> GroveQuillColors {
        GroveQuillColors(barbLow: theme.ink.opacity(0.3).nsColor, barbHigh: theme.ink.opacity(0.3).nsColor,
                         shaft: theme.ink.opacity(0.45).nsColor)
    }

    /// One colour for the barbs and another for the shaft, for a quill on a light surface.
    static func flat(barbs: NSColor, shaft: NSColor) -> GroveQuillColors {
        GroveQuillColors(barbLow: barbs, barbHigh: barbs, shaft: shaft)
    }

    private static func color(_ hex: UInt32) -> NSColor { QuillColor(hex: hex).nsColor }
}

/// The voice quill as live layers: `BrandMarkView` in SwiftUI. Every frame of its motion runs on
/// the render server. While listening, the level reaches the layers through `GroveHaloSource`,
/// never through view state, so a level update invalidates no view.
struct GroveQuill: NSViewRepresentable {
    var motion: BrandMarkView.Motion = .still
    var colors: GroveQuillColors
    /// The level source, while listening.
    var source: GroveHaloSource?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    func makeNSView(context: Context) -> BrandMarkView { BrandMarkView(frame: .zero) }

    func updateNSView(_ view: BrandMarkView, context: Context) {
        view.pixelScale = displayScale
        view.reduceMotion = reduceMotion
        view.setColors(barbLow: colors.barbLow, barbHigh: colors.barbHigh, shaft: colors.shaft)
        if view.motion != motion { view.play(motion, animated: true) }
        if motion == .listening { source?.quill = view }
    }

    static func dismantleNSView(_ view: BrandMarkView, coordinator: ()) { view.stop() }
}

// MARK: - Feedback: confirmations and dialogs

/// A short note in the window, and the one confirmation dialog at a time.
///
/// Notes are announced to VoiceOver as they appear. They replace the native alert and the
/// silent clipboard write: Copy and delete say what happened where the person is looking.
@MainActor
final class GroveFeedback: ObservableObject {
    struct Notice: Identifiable, Equatable {
        enum Tone: Equatable { case ok, caution, quiet }
        struct Action {
            var title: String
            var handler: () -> Void
        }

        let id = UUID()
        var text: String
        var systemImage: String
        var tone: Tone
        var action: Action?

        static func == (lhs: Notice, rhs: Notice) -> Bool {
            lhs.id == rhs.id && lhs.text == rhs.text && lhs.systemImage == rhs.systemImage && lhs.tone == rhs.tone
                && lhs.action?.title == rhs.action?.title
        }
    }

    struct Dialog: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var confirmTitle: String
        var isDestructive: Bool
        var onConfirm: () -> Void
        var onCancel: (() -> Void)?
    }

    /// How long a note stays: a note with an action stays a little longer.
    static let plainDuration: Duration = .seconds(2.8)
    static let actionDuration: Duration = .seconds(6)

    @Published private(set) var notice: Notice?
    @Published private(set) var dialog: Dialog?

    /// Replaced in tests to see what VoiceOver would be told.
    var announce: @MainActor (String) -> Void = GroveFeedback.announceToVoiceOver
    private var dismissTask: Task<Void, Never>?

    init() {}

    func post(_ text: String, systemImage: String = "checkmark", tone: Notice.Tone = .ok,
              action: Notice.Action? = nil) {
        let notice = Notice(text: text, systemImage: systemImage, tone: tone, action: action)
        self.notice = notice
        announce(text)
        dismissTask?.cancel()
        let duration = action == nil ? Self.plainDuration : Self.actionDuration
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismissNotice(ifShowing: notice.id)
        }
    }

    func dismissNotice(ifShowing id: UUID? = nil) {
        guard id == nil || notice?.id == id else { return }
        dismissTask?.cancel()
        dismissTask = nil
        notice = nil
    }

    func confirm(title: String, message: String, confirmTitle: String, isDestructive: Bool = true,
                 onConfirm: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        dialog = Dialog(title: title, message: message, confirmTitle: confirmTitle,
                        isDestructive: isDestructive, onConfirm: onConfirm, onCancel: onCancel)
    }

    func resolveDialog(confirmed: Bool) {
        guard let dialog else { return }
        self.dialog = nil
        if confirmed { dialog.onConfirm() } else { dialog.onCancel?() }
    }

    static func announceToVoiceOver(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

extension EnvironmentValues {
    /// Set by the Grove window. Views outside it have none and skip their confirmations.
    @Entry var groveFeedback: GroveFeedback?
}

/// The short note at the bottom of the window.
struct GroveNoticeView: View {
    let notice: GroveFeedback.Notice
    @Environment(\.groveTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(notice.tone == .caution ? theme.warningColor : theme.mintColor)
                .accessibilityHidden(true)
            Text(notice.text)
                .groveFont(13, .medium)
                .foregroundStyle(theme.creamColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let action = notice.action {
                Button(action.title, action: action.handler)
                    .buttonStyle(.grove(.soft, .small))
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, notice.action == nil ? 18 : 8)
        .padding(.vertical, notice.action == nil ? 10 : 6)
        .forestGlass(cornerRadius: 22, isWorkingSurface: false)
        .shadow(color: theme.shadowTintColor.opacity(theme.isDark ? 0.6 : 0.3), radius: 14, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice.text)
    }
}

/// A confirmation: a title, one sentence and two buttons, in a raised card over a soft scrim.
struct GroveDialogView: View {
    let dialog: GroveFeedback.Dialog
    var onResolve: (Bool) -> Void
    @Environment(\.groveTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dialog.title)
                .groveFont(15, .semibold)
                .foregroundStyle(theme.inkColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !dialog.message.isEmpty {
                Text(dialog.message)
                    .groveFont(13)
                    .foregroundStyle(theme.ink2Color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { onResolve(false) }
                    .buttonStyle(.grove(.outline))
                    .keyboardShortcut(.cancelAction)
                Button(dialog.confirmTitle) { onResolve(true) }
                    .buttonStyle(.grove(dialog.isDestructive ? .danger : .primary))
                    // Return confirms only what can be taken back; a delete needs a click.
                    .keyboardShortcut(dialog.isDestructive ? nil : .defaultAction)
            }
            .padding(.top, 10)
        }
        .padding(20)
        .frame(width: 372, alignment: .leading)
        .background(GroveCardBackground(radius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// Draws the note and the dialog above the window's content.
struct GroveFeedbackLayer: ViewModifier {
    @ObservedObject var feedback: GroveFeedback
    @Environment(\.groveTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack {
            content
                .environment(\.groveFeedback, feedback)
                .disabled(feedback.dialog != nil)
            VStack {
                Spacer(minLength: 0)
                if let notice = feedback.notice {
                    GroveNoticeView(notice: notice)
                        .padding(.bottom, 26)
                        .padding(.horizontal, 24)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
                        .id(notice.id)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1),
                       value: feedback.notice)
            if let dialog = feedback.dialog {
                ZStack {
                    Rectangle()
                        .fill(theme.shadowTintColor.opacity(theme.isDark ? 0.6 : 0.3))
                        .ignoresSafeArea()
                        .onTapGesture { feedback.resolveDialog(confirmed: false) }
                        .accessibilityHidden(true)
                    GroveDialogView(dialog: dialog) { feedback.resolveDialog(confirmed: $0) }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: feedback.dialog?.id)
    }
}

extension View {
    func groveFeedbackLayer(_ feedback: GroveFeedback) -> some View {
        modifier(GroveFeedbackLayer(feedback: feedback))
    }
}

extension Array {
    /// Whether both arrays are the same buffer, which is a constant-time way to know that
    /// nothing in them changed. A change to one of two arrays that share a buffer copies it
    /// first, so a holder of the earlier array can rely on this staying true only while the
    /// content is untouched. False for two equal arrays that were built apart.
    func sharesBuffer(with other: [Element]) -> Bool {
        guard count == other.count else { return false }
        return withUnsafeBufferPointer { mine in
            other.withUnsafeBufferPointer { theirs in mine.baseAddress == theirs.baseAddress }
        }
    }
}
