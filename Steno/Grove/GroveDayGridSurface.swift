import AppKit
import StenoKit
import SwiftUI

/// The calendar's day cells, drawn in one view. Each cell used to be its own button with a
/// shape, an outline, a tooltip and an accessibility label, about 180 of them, and building
/// them was most of the time Insights took to open. Here the cells are painted in one pass, a
/// click picks the cell under the pointer, tooltips are rectangles of the one view, and
/// VoiceOver gets a button per day when it asks.
struct GroveDayGridSurface: NSViewRepresentable {
    struct Colors: Equatable {
        var empty: NSColor
        /// Levels 1 to 4, pale green to forest.
        var levels: [NSColor]
        /// A day before Steno kept counts.
        var uncounted: NSColor
        var selected: NSColor
    }

    let weeks: [UsageCalendarWeek]
    let size: CGFloat
    let gap: CGFloat
    let maximumWords: Int
    let calendar: Calendar
    let selectedDate: Date?
    let colors: Colors
    /// The tooltip: the date and the day's figures as they are shown.
    let label: (UsageCalendarCell) -> String
    /// What VoiceOver reads: the same, in words rather than symbols and units.
    let spokenLabel: (UsageCalendarCell) -> String
    let onSelect: (Date) -> Void

    static func width(columns: Int, size: CGFloat, gap: CGFloat) -> CGFloat {
        CGFloat(columns) * size + CGFloat(max(0, columns - 1)) * gap
    }

    static func height(size: CGFloat, gap: CGFloat) -> CGFloat { 7 * size + 6 * gap }

    func makeNSView(context: Context) -> GroveDayGridView { GroveDayGridView() }

    func updateNSView(_ view: GroveDayGridView, context: Context) {
        view.update(self)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GroveDayGridView, context: Context) -> CGSize? {
        CGSize(width: Self.width(columns: weeks.count, size: size, gap: gap), height: Self.height(size: size, gap: gap))
    }
}

final class GroveDayGridView: NSView, NSViewToolTipOwner {
    private var model: GroveDayGridSurface?
    private var pressed: (week: Int, row: Int)?
    /// The days handed to accessibility clients. A client in another process reads each one in
    /// later calls, so they live as long as the calendar they describe.
    private var dayElements: [GroveDayCellElement]?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ new: GroveDayGridSurface) {
        let old = model
        model = new
        let sameShape = old.map {
            $0.weeks.sharesBuffer(with: new.weeks) && $0.size == new.size && $0.gap == new.gap
        } ?? false
        let same = sameShape && old.map {
            $0.maximumWords == new.maximumWords && $0.selectedDate == new.selectedDate && $0.colors == new.colors
        } ?? false
        if !sameShape { rebuildToolTips() }
        if !same {
            dayElements = nil
            needsDisplay = true
        }
    }

    // MARK: Geometry

    private func rect(week: Int, row: Int) -> CGRect {
        guard let model else { return .zero }
        let pitch = model.size + model.gap
        return CGRect(x: CGFloat(week) * pitch, y: CGFloat(row) * pitch, width: model.size, height: model.size)
    }

    /// The in-range cell under `point`, or nil outside the grid or on a day outside the range. Each
    /// cell takes half of the gap on every side, so the target is the cell and its gaps, never
    /// smaller than the pitch, while the squares drawn stay as they are.
    private func cell(at point: NSPoint) -> (week: Int, row: Int)? {
        guard let model else { return nil }
        let pitch = model.size + model.gap
        let week = Int(((point.x + model.gap / 2) / pitch).rounded(.down))
        let row = Int(((point.y + model.gap / 2) / pitch).rounded(.down))
        guard (0..<model.weeks.count).contains(week), (0..<7).contains(row) else { return nil }
        return model.weeks[week].cells[row].isInRange ? (week, row) : nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let context = NSGraphicsContext.current?.cgContext else { return }
        let shape = RoundedRectangle(cornerRadius: model.size * 0.21, style: .continuous)
        for (weekIndex, week) in model.weeks.enumerated() {
            for (row, cell) in week.cells.enumerated() where cell.isInRange {
                let frame = rect(week: weekIndex, row: row)
                guard frame.intersects(dirtyRect.insetBy(dx: -3, dy: -3)) else { continue }
                let fill: NSColor
                if let usage = cell.usage, usage.isTracked {
                    let level = usage.isActive ? GroveDayGrid.level(words: usage.wordCount, maximum: model.maximumWords) : 0
                    fill = level == 0 ? model.colors.empty : model.colors.levels[min(level, 4) - 1]
                } else {
                    fill = model.colors.uncounted
                }
                context.setFillColor(fill.cgColor)
                context.addPath(shape.path(in: frame).cgPath)
                context.fillPath()
                if let selected = model.selectedDate, model.calendar.isDate(selected, inSameDayAs: cell.date) {
                    stroke(shape.inset(by: 1).path(in: frame.insetBy(dx: -2, dy: -2)), width: 2, color: model.colors.selected, in: context)
                }
            }
        }
    }

    private func stroke(_ path: Path, width: CGFloat, color: NSColor, in context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.addPath(path.cgPath)
        context.strokePath()
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        pressed = cell(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let model, let pressed, let released = cell(at: convert(event.locationInWindow, from: nil)),
              released == pressed else { return }
        model.onSelect(model.weeks[released.week].cells[released.row].date)
    }

    // MARK: Tooltips

    private func rebuildToolTips() {
        removeAllToolTips()
        guard let model else { return }
        for (weekIndex, week) in model.weeks.enumerated() {
            for (row, cell) in week.cells.enumerated() where cell.isInRange {
                addToolTip(rect(week: weekIndex, row: row), owner: self, userData: UnsafeMutableRawPointer(bitPattern: weekIndex * 8 + row + 1))
            }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let model, let data else { return "" }
        let code = Int(bitPattern: data) - 1
        let week = code / 8, row = code % 8
        guard model.weeks.indices.contains(week), row < 7 else { return "" }
        return model.label(model.weeks[week].cells[row])
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityChildren() -> [Any]? {
        guard let model else { return [] }
        if let dayElements { return dayElements }
        var elements: [GroveDayCellElement] = []
        for (weekIndex, week) in model.weeks.enumerated() {
            for (row, cell) in week.cells.enumerated() where cell.isInRange {
                let element = GroveDayCellElement()
                element.setAccessibilityRole(.button)
                element.setAccessibilityParent(self)
                element.setAccessibilityLabel(model.spokenLabel(cell))
                element.setAccessibilityFrameInParentSpace(rect(week: weekIndex, row: row))
                element.setAccessibilitySelected(model.selectedDate.map { model.calendar.isDate($0, inSameDayAs: cell.date) } ?? false)
                element.press = { [weak self] in self?.model?.onSelect(cell.date) }
                elements.append(element)
            }
        }
        dayElements = elements
        return elements
    }
}

/// One day for VoiceOver: a button that picks the day.
final class GroveDayCellElement: NSAccessibilityElement {
    var press: () -> Void = {}

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}
