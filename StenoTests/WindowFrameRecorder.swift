import AppKit
import CoreGraphics
import Darwin

/// Records what the window server composites for one window, many times a second, from a
/// background thread, so a transition can be read frame by frame: the window's own pixels
/// (with its alpha applied), whether it is on screen, and its bounds. Labelled marks (a call
/// made, a trace line from the code under test) are kept on the same clock.
///
/// Capturing a window that belongs to this process needs no Screen Recording permission.
/// `CGWindowListCreateImage` is obsoleted in the macOS 15 SDK for Swift, but the symbol still
/// exists and still captures; it is looked up at run time.
final class WindowFrameRecorder: @unchecked Sendable {
    struct Frame {
        /// `CACurrentMediaTime()` when the capture was taken.
        let time: CFTimeInterval
        let image: CGImage?
        let isOnscreen: Bool
        let alpha: Double
        /// In global display coordinates, origin at the top left of the main display.
        let bounds: CGRect
    }

    struct Mark {
        let time: CFTimeInterval
        let label: String
    }

    struct Recording {
        let start: CFTimeInterval
        let frames: [Frame]
        let marks: [Mark]

        /// Frames that were on screen, with the marks that came before each.
        var visibleFrames: [Frame] { frames.filter { $0.isOnscreen && $0.alpha > 0.01 } }

        /// The marks between `from` (exclusive) and `to` (inclusive).
        func marks(after from: CFTimeInterval, upTo to: CFTimeInterval) -> [Mark] {
            marks.filter { $0.time > from && $0.time <= to }
        }

        /// The first mark whose label contains `text`.
        func time(of text: String) -> CFTimeInterval? { marks.first { $0.label.contains(text) }?.time }
    }

    private let windowID: CGWindowID
    private let interval: TimeInterval
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var marks: [Mark] = []
    private var isRunning = false
    private var finished: DispatchSemaphore?
    private var startTime: CFTimeInterval = 0

    /// `interval` defaults to 240 captures a second, four per 60 Hz display frame, so a state
    /// that is composited for a single display frame is still seen.
    init(windowID: CGWindowID, interval: TimeInterval = 1.0 / 240) {
        self.windowID = windowID
        self.interval = interval
    }

    func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        frames = []
        marks = []
        startTime = CACurrentMediaTime()
        let done = DispatchSemaphore(value: 0)
        finished = done
        lock.unlock()
        let thread = Thread { [self] in
            while true {
                lock.lock()
                let running = isRunning
                lock.unlock()
                guard running else { break }
                let frame = Self.capture(windowID)
                lock.lock()
                frames.append(frame)
                lock.unlock()
                let next = frame.time + interval
                let wait = next - CACurrentMediaTime()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
            done.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops capturing and returns everything recorded since `start()`.
    func stop() -> Recording {
        lock.lock()
        isRunning = false
        let done = finished
        lock.unlock()
        done?.wait()
        lock.lock()
        defer { lock.unlock() }
        return Recording(start: startTime, frames: frames, marks: marks)
    }

    /// Whether a mark containing any of `texts` has been added. Safe from any thread.
    func hasMark(containing texts: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return marks.contains { mark in texts.contains { mark.label.contains($0) } }
    }

    /// Adds a labelled moment on the capture clock. Safe from any thread.
    func mark(_ label: String) {
        let time = CACurrentMediaTime()
        lock.lock()
        marks.append(Mark(time: time, label: label))
        lock.unlock()
    }

    /// Adds a frame captured now, on the calling thread, labelled. With `flush`, the calling
    /// thread's pending Core Animation changes are committed first, so the frame shows what the
    /// window server would draw if it composited at this instant.
    func captureNow(label: String, flush: Bool) {
        if flush { CATransaction.flush() }
        let frame = Self.capture(windowID)
        lock.lock()
        marks.append(Mark(time: frame.time, label: label))
        frames.append(frame)
        frames.sort { $0.time < $1.time }
        lock.unlock()
    }

    // MARK: - Capture

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static let createImage: CreateImage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    static var isAvailable: Bool { createImage != nil }

    static func capture(_ windowID: CGWindowID) -> Frame {
        let time = CACurrentMediaTime()
        var isOnscreen = false
        var alpha = 0.0
        var bounds = CGRect.zero
        if let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]], let entry = info.first {
            isOnscreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
            alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 0
            if let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: dictionary) {
                bounds = rect
            }
        }
        // Including only this window; its own bounds, without the frame; at nominal resolution.
        // The pixels are read from the window server later, when the frame is examined; it keeps
        // the picture as it was at the capture.
        let image = createImage?(.null, CGWindowListOption.optionIncludingWindow.rawValue, windowID,
                                 CGWindowImageOption([.boundsIgnoreFraming, .nominalResolution]).rawValue)?.takeRetainedValue()
        return Frame(time: time, image: image, isOnscreen: isOnscreen, alpha: alpha, bounds: bounds)
    }

    /// Whether the window server is drawing windows of this process and handing their pixels
    /// back: false while the displays sleep, when a capture comes back blank after a second.
    @MainActor
    static let canCaptureWindows: Bool = {
        guard createImage != nil else { return false }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.animationBehavior = .none
        panel.isOpaque = true
        panel.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        panel.level = .floating
        if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY)) }
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let started = CACurrentMediaTime()
        guard let image = capture(CGWindowID(panel.windowNumber)).image,
              let pixel = NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB)
        else { return false }
        // Red, give or take the display's colour space; a sleeping display gives transparent black.
        return CACurrentMediaTime() - started < 0.5 && pixel.redComponent > 0.7 && pixel.greenComponent < 0.5
            && pixel.blueComponent < 0.5
    }()
}

// MARK: - Reading frames

extension WindowFrameRecorder.Frame {
    /// The bounding box, in image pixels with the origin at the top left, of the pixels whose
    /// alpha is at least `threshold`. Nil when none are.
    func opaqueBox(threshold: CGFloat = 0.6) -> CGRect? {
        guard let image else { return nil }
        return Self.opaqueBox(of: image, threshold: threshold)
    }

    static func opaqueBox(of image: CGImage, threshold: CGFloat) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let limit = UInt8(max(0, min(255, threshold * 255)))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] >= limit {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

// MARK: - Contact sheets

enum FrameContactSheet {
    /// Writes the recording as a contact sheet: one cell per distinct on-screen picture (repeats
    /// folded into a count), over a stand-in desktop, each labelled with its time from the start,
    /// the window's alpha, and the marks that came before it. Off-screen spans become one grey
    /// cell. Returns the cells' count.
    @discardableResult
    static func write(
        _ recording: WindowFrameRecorder.Recording, title: String, to url: URL,
        columns: Int = 8, desktop: NSColor = NSColor(srgbRed: 0.82, green: 0.84, blue: 0.86, alpha: 1)
    ) throws -> Int {
        struct Cell {
            var frame: WindowFrameRecorder.Frame
            var count: Int
            var marks: [String]
        }
        var cells: [Cell] = []
        var lastTime = recording.start
        var lastKey: Int?
        for frame in recording.frames {
            let marks = recording.marks(after: lastTime, upTo: frame.time).map(\.label)
            lastTime = frame.time
            let visible = frame.isOnscreen && frame.alpha > 0.01
            let key = visible ? fingerprint(frame) : -1
            if key == lastKey, marks.isEmpty, var last = cells.popLast() {
                last.count += 1
                cells.append(last)
                continue
            }
            lastKey = key
            cells.append(Cell(frame: frame, count: 1, marks: marks))
        }
        let trailing = recording.marks(after: lastTime, upTo: .greatestFiniteMagnitude).map(\.label)
        if !trailing.isEmpty, var last = cells.popLast() {
            last.marks += trailing
            cells.append(last)
        }

        // Every cell shows the same region of the display: the union of the window's bounds.
        let union = recording.frames.filter { $0.bounds.width > 0 }.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        let region = union.isNull ? CGRect(x: 0, y: 0, width: 400, height: 120) : union
        let cellWidth = region.width
        let labelHeight: CGFloat = 54
        let cellHeight = region.height + labelHeight
        let gap: CGFloat = 8
        let header: CGFloat = 30
        let rows = max(1, Int(ceil(Double(cells.count) / Double(columns))))
        let size = CGSize(
            width: CGFloat(min(columns, max(1, cells.count))) * (cellWidth + gap) + gap,
            height: header + CGFloat(rows) * (cellHeight + gap) + gap
        )
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return 0 }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.15, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        (title as NSString).draw(at: NSPoint(x: gap, y: size.height - header + 8), withAttributes: titleAttributes)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.white,
        ]
        for (index, cell) in cells.enumerated() {
            let column = index % columns
            let row = index / columns
            let origin = CGPoint(
                x: gap + CGFloat(column) * (cellWidth + gap),
                y: size.height - header - CGFloat(row + 1) * (cellHeight + gap)
            )
            let picture = CGRect(x: origin.x, y: origin.y + labelHeight, width: cellWidth, height: region.height)
            let visible = cell.frame.isOnscreen && cell.frame.alpha > 0.01
            (visible ? desktop : NSColor(white: 0.35, alpha: 1)).setFill()
            picture.fill()
            if visible, let image = cell.frame.image {
                // Bounds are top-left based; the sheet is bottom-left based.
                let local = CGRect(
                    x: picture.minX + cell.frame.bounds.minX - region.minX,
                    y: picture.maxY - (cell.frame.bounds.maxY - region.minY),
                    width: cell.frame.bounds.width, height: cell.frame.bounds.height
                )
                NSGraphicsContext.current?.cgContext.draw(image, in: local)
            }
            let ms = Int(((cell.frame.time - recording.start) * 1000).rounded())
            var text = "\(index) t=\(ms)ms ×\(cell.count) " + (visible ? String(format: "a=%.2f", cell.frame.alpha) : "OFF")
            if let box = visible ? cell.frame.opaqueBox() : nil { text += " box=\(Int(box.width))x\(Int(box.height))" }
            for mark in cell.marks.suffix(4) { text += "\n› " + String(mark.prefix(60)) }
            (text as NSString).draw(
                in: NSRect(x: origin.x + 2, y: origin.y, width: cellWidth - 4, height: labelHeight), withAttributes: labelAttributes
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return 0 }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return cells.count
    }

    /// A cheap fingerprint of a frame's picture: its bounds, alpha and a sparse pixel sample.
    private static func fingerprint(_ frame: WindowFrameRecorder.Frame) -> Int {
        var hasher = Hasher()
        hasher.combine(Int(frame.bounds.minX)); hasher.combine(Int(frame.bounds.minY))
        hasher.combine(Int(frame.bounds.width)); hasher.combine(Int(frame.bounds.height))
        hasher.combine(Int(frame.alpha * 100))
        guard let image = frame.image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return hasher.finalize()
        }
        let length = CFDataGetLength(data)
        let step = max(4, length / 4096) & ~3
        var offset = 0
        while offset < length {
            hasher.combine(bytes[offset]); hasher.combine(bytes[offset + 3 < length ? offset + 3 : offset])
            offset += step
        }
        return hasher.finalize()
    }
}

extension WindowFrameRecorder.Frame {
    /// The brightest pixel in `rect` (window points, origin at the top left), as the least of its
    /// premultiplied red, green and blue: light words over a dark island read near 1, the island
    /// and transparent pixels near 0.
    func brightness(in rect: CGRect) -> CGFloat {
        guard let image else { return 0 }
        let scale = bounds.width > 0 ? CGFloat(image.width) / bounds.width : 1
        let crop = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !crop.isEmpty, let part = image.cropping(to: crop) else { return 0 }
        let width = part.width, height = part.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var brightest: UInt8 = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            brightest = max(brightest, min(pixels[index], pixels[index + 1], pixels[index + 2]))
        }
        return CGFloat(brightest) / 255
    }
}

extension WindowFrameRecorder.Frame {
    /// How opaque the window's most opaque pixel is on screen: the window's alpha times the
    /// largest alpha in its picture. A window can stay opaque while its content fades.
    var opacity: Double {
        guard isOnscreen, alpha > 0, let image else { return 0 }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var peak: UInt8 = 0
        for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] > peak { peak = pixels[index] }
        return alpha * Double(peak) / 255
    }
}
