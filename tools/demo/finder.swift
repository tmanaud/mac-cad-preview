import Cocoa
import UniformTypeIdentifiers

// The Finder in column view with its preview column, for the README. The
// window, sidebar and columns are drawn here from the demo project folder;
// the preview in the column is the extension's own view controller, which is
// what the Finder shows there. Folders and documents use the system's generic
// icons, so the picture does not depend on the apps the rendering Mac has.

private struct Entry {
    let name: String
    let url: URL
    let isFolder: Bool
}

private struct FinderState {
    var folder: Int          // selected row in the first column
    var file: Int?           // selected row in the second column
    var filesFocused: Bool   // which column holds the active, accent-coloured selection
}

extension Studio {

    // Geometry, in window points with the origin at the bottom left.
    private var finderSize: NSSize { NSSize(width: 1120, height: 660) }
    private var toolbarHeight: CGFloat { 52 }
    private var sidebarWidth: CGFloat { 196 }
    private var rowHeight: CGFloat { 22 }

    private var folderColumn: NSRect {
        NSRect(x: sidebarWidth, y: 0, width: 176, height: finderSize.height - toolbarHeight)
    }

    private var fileColumn: NSRect {
        NSRect(x: folderColumn.maxX, y: 0, width: 212, height: folderColumn.height)
    }

    private var previewColumn: NSRect {
        NSRect(x: fileColumn.maxX, y: 0, width: finderSize.width - fileColumn.maxX, height: folderColumn.height)
    }

    private var previewArea: NSRect {
        NSRect(x: previewColumn.minX + 24, y: previewColumn.maxY - 20 - 350,
               width: previewColumn.width - 48, height: 350)
    }

    // MARK: - Scene

    /// Browses the demo project: the gear pump, then the vase and the
    /// planetary set, each previewed in 3D as it is selected, and back to the
    /// gear pump so the animation loops without a seam.
    func recordFinder(project: URL) {
        framesFolder = "finder-frames"
        frameNumber = 0
        do {
            try FileManager.default.createDirectory(at: output.appendingPathComponent(framesFolder),
                                                    withIntermediateDirectories: true)
        } catch {
            fail("cannot create \(framesFolder): \(error.localizedDescription)")
        }
        content = previewArea.size

        let folders = entries(in: project).filter(\.isFolder)
        guard let cad = folders.firstIndex(where: { $0.name == "cad" }),
              let print = folders.firstIndex(where: { $0.name == "print" }) else {
            fail("the demo project has no cad or print folder")
        }
        let cadFiles = entries(in: folders[cad].url)
        let printFiles = entries(in: folders[print].url)
        guard let pump = cadFiles.firstIndex(where: { $0.name == "gear-pump.step" }),
              let vase = printFiles.firstIndex(where: { $0.name == "vase.stl" }),
              let plate = printFiles.firstIndex(where: { $0.name == "planetary-set.3mf" }) else {
            fail("the demo project is missing a model")
        }

        func window(_ state: FinderState, preview: CGImage?) -> CGImage {
            finderWindow(state, folders: folders, files: entries(in: folders[state.folder].url), preview: preview)
        }

        var state = FinderState(folder: cad, file: pump, filesFocused: true)
        let opening = window(state, preview: preview(cadFiles[pump].url))
        writePNG(finderFrame([(opening, 1)], pointer: nil), to: output.appendingPathComponent("finder-still.png"))

        var pointer = rowPoint(fileColumn, row: pump)
        var current = opening
        holdFinder(current, frames: 24, pointer: pointer)

        // Into print: the second column lists its files and nothing is previewed.
        pointer = moveFinderPointer(over: current, from: pointer, to: rowPoint(folderColumn, row: print), frames: 18)
        state = FinderState(folder: print, file: nil, filesFocused: false)
        current = clickFinder(at: pointer, before: current, after: window(state, preview: nil))

        for target in [vase, plate] {
            pointer = moveFinderPointer(over: current, from: pointer, to: rowPoint(fileColumn, row: target), frames: 14)
            state = FinderState(folder: print, file: target, filesFocused: true)
            let selected = window(state, preview: nil)
            current = clickFinder(at: pointer, before: current, after: selected)
            current = fadeFinder(from: selected, to: window(state, preview: preview(printFiles[target].url)),
                                 frames: 6, pointer: pointer)
            holdFinder(current, frames: 30, pointer: pointer)
        }

        // Back to cad and the gear pump: the opening frame again.
        pointer = moveFinderPointer(over: current, from: pointer, to: rowPoint(folderColumn, row: cad), frames: 16)
        state = FinderState(folder: cad, file: nil, filesFocused: false)
        current = clickFinder(at: pointer, before: current, after: window(state, preview: nil))
        pointer = moveFinderPointer(over: current, from: pointer, to: rowPoint(fileColumn, row: pump), frames: 12)
        state = FinderState(folder: cad, file: pump, filesFocused: true)
        let reselected = window(state, preview: nil)
        current = clickFinder(at: pointer, before: current, after: reselected)
        current = fadeFinder(from: reselected, to: opening, frames: 6, pointer: pointer)
        holdFinder(current, frames: 12, pointer: pointer)
    }

    private func preview(_ url: URL) -> CGImage {
        open(url, background: .controlBackgroundColor)
        return contentImage()
    }

    private func entries(in folder: URL) -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return urls.map { url in
            Entry(name: url.lastPathComponent, url: url,
                  isFolder: (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Timeline

    private func holdFinder(_ image: CGImage, frames: Int, pointer: NSPoint) {
        let still = finderFrame([(image, 1)], pointer: (pointer, false))
        for _ in 0..<frames { emit(still) }
    }

    private func moveFinderPointer(over image: CGImage, from: NSPoint, to: NSPoint, frames: Int) -> NSPoint {
        for i in 1...frames {
            emit(finderFrame([(image, 1)], pointer: (mix(from, to, ease(CGFloat(i) / CGFloat(frames))), false)))
        }
        return to
    }

    private func clickFinder(at point: NSPoint, before: CGImage, after: CGImage) -> CGImage {
        for _ in 0..<3 { emit(finderFrame([(before, 1)], pointer: (point, true))) }
        emit(finderFrame([(after, 1)], pointer: (point, false)))
        return after
    }

    private func fadeFinder(from: CGImage, to: CGImage, frames: Int, pointer: NSPoint) -> CGImage {
        for i in 1...frames {
            emit(finderFrame([(from, 1), (to, ease(CGFloat(i) / CGFloat(frames)))], pointer: (pointer, false)))
        }
        return to
    }

    // MARK: - Drawing

    private func finderFrame(_ layers: [(CGImage, CGFloat)], pointer: (NSPoint, Bool)?) -> CGImage {
        let canvas = NSSize(width: finderSize.width + 2 * margin, height: finderSize.height + 2 * margin)
        let context = bitmap(width: Int(canvas.width * scale), height: Int(canvas.height * scale))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        theme.appearance.performAsCurrentDrawingAppearance {
            let frame = NSRect(x: margin, y: margin, width: finderSize.width, height: finderSize.height)
            let body = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(theme == .dark ? 0.55 : 0.28)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            NSColor.windowBackgroundColor.setFill()
            body.fill()
            NSGraphicsContext.restoreGraphicsState()

            context.saveGState()
            body.addClip()
            for (image, alpha) in layers {
                context.setAlpha(alpha)
                context.draw(image, in: frame)
            }
            context.restoreGState()

            let edge = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
            edge.lineWidth = 1
            NSColor(white: theme == .dark ? 1 : 0, alpha: theme == .dark ? 0.18 : 0.16).setStroke()
            edge.stroke()
            if let pointer {
                drawPointer(at: NSPoint(x: margin + pointer.0.x, y: margin + pointer.0.y), pressed: pointer.1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { fail("could not draw a Finder frame") }
        return image
    }

    /// The window's inside, without its outline: sidebar, toolbar, the two
    /// columns and the preview column.
    private func finderWindow(_ state: FinderState, folders: [Entry], files: [Entry],
                              preview: CGImage?) -> CGImage {
        let context = bitmap(width: Int(finderSize.width * scale), height: Int(finderSize.height * scale))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        theme.appearance.performAsCurrentDrawingAppearance {
            NSColor.controlBackgroundColor.setFill()
            NSRect(origin: .zero, size: finderSize).fill()
            drawSidebar()
            drawToolbar(title: folders[state.folder].name)
            drawColumn(folderColumn, entries: folders, selected: state.folder, focused: !state.filesFocused)
            drawColumn(fileColumn, entries: files, selected: state.file, focused: state.filesFocused)
            NSColor.separatorColor.setFill()
            for x in [sidebarWidth, folderColumn.maxX, fileColumn.maxX] {
                NSRect(x: x - 0.5, y: 0, width: 1, height: folderColumn.height).fill()
            }
            if let preview, let index = state.file {
                drawPreview(preview, of: files[index], in: context)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { fail("could not draw the Finder window") }
        return image
    }

    private func drawSidebar() {
        let height = finderSize.height
        NSColor(white: theme == .dark ? 0.17 : 0.925, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: sidebarWidth, height: height).fill()

        let lights = [NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
                      NSColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1),
                      NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)]
        for (i, colour) in lights.enumerated() {
            let light = NSRect(x: 12 + CGFloat(i) * 20, y: height - 32, width: 12, height: 12)
            colour.setFill()
            NSBezierPath(ovalIn: light).fill()
            NSColor(white: 0, alpha: 0.12).setStroke()
            let ring = NSBezierPath(ovalIn: light.insetBy(dx: 0.25, dy: 0.25))
            ring.lineWidth = 0.5
            ring.stroke()
        }

        var top = height - toolbarHeight - 8
        func header(_ text: String) {
            top -= 20
            draw(text, at: NSPoint(x: 18, y: top), size: 11, weight: .semibold, colour: .secondaryLabelColor)
            top -= 4
        }
        func item(_ symbol: String, _ name: String, selected: Bool = false) {
            let row = NSRect(x: 10, y: top - 26, width: sidebarWidth - 20, height: 26)
            if selected {
                NSColor(white: theme == .dark ? 1 : 0, alpha: theme == .dark ? 0.10 : 0.08).setFill()
                NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
            }
            drawSymbol(symbol, centre: NSPoint(x: 29, y: row.midY), size: 14, colour: .systemBlue)
            draw(name, at: NSPoint(x: 46, y: row.midY), size: 13, centredVertically: true)
            top -= 28
        }
        header("Favourites")
        item("clock", "Recents")
        item("square.grid.2x2", "Applications")
        item("menubar.dock.rectangle", "Desktop")
        item("doc", "Documents")
        item("arrow.down.circle", "Downloads")
        item("folder", "gear-pump", selected: true)
        top -= 8
        header("Locations")
        item("internaldrive", "Macintosh HD")
    }

    private func drawToolbar(title: String) {
        let bar = NSRect(x: sidebarWidth, y: finderSize.height - toolbarHeight,
                         width: finderSize.width - sidebarWidth, height: toolbarHeight)
        NSColor.controlBackgroundColor.setFill()
        bar.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bar.minX, y: bar.minY - 0.5, width: bar.width, height: 1).fill()

        let middle = bar.midY
        drawSymbol("chevron.left", centre: NSPoint(x: bar.minX + 22, y: middle), size: 14)
        drawSymbol("chevron.right", centre: NSPoint(x: bar.minX + 46, y: middle), size: 14,
                   colour: .tertiaryLabelColor)
        draw(title, at: NSPoint(x: bar.minX + 66, y: middle), size: 13, weight: .bold, centredVertically: true)

        // Icon, list, column and gallery view, with column view chosen.
        let modes = ["square.grid.2x2", "list.bullet", "rectangle.split.3x1", "rectangle.on.rectangle"]
        for (i, name) in modes.enumerated() {
            let centre = NSPoint(x: bar.maxX - 250 + CGFloat(i) * 32, y: middle)
            if i == 2 {
                NSColor(white: theme == .dark ? 1 : 0, alpha: theme == .dark ? 0.12 : 0.08).setFill()
                NSBezierPath(roundedRect: NSRect(x: centre.x - 15, y: centre.y - 12, width: 30, height: 24),
                             xRadius: 6, yRadius: 6).fill()
            }
            drawSymbol(name, centre: centre, size: 13)
        }
        drawSymbol("square.and.arrow.up", centre: NSPoint(x: bar.maxX - 84, y: middle + 1), size: 14)
        drawSymbol("magnifyingglass", centre: NSPoint(x: bar.maxX - 40, y: middle), size: 14)
    }

    private func rowRect(_ column: NSRect, row: Int) -> NSRect {
        NSRect(x: column.minX + 6, y: column.maxY - 8 - CGFloat(row + 1) * rowHeight,
               width: column.width - 12, height: rowHeight)
    }

    /// Where the pointer clicks a row, in window coordinates.
    private func rowPoint(_ column: NSRect, row: Int) -> NSPoint {
        let rect = rowRect(column, row: row)
        return NSPoint(x: rect.minX + 56, y: rect.midY - 3)
    }

    private func drawColumn(_ column: NSRect, entries: [Entry], selected: Int?, focused: Bool) {
        for (row, entry) in entries.enumerated() {
            let rect = rowRect(column, row: row)
            let isSelected = row == selected
            if isSelected {
                (focused ? NSColor.selectedContentBackgroundColor
                         : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            let icon = NSWorkspace.shared.icon(for: entry.isFolder ? .folder : .data)
            icon.draw(in: NSRect(x: rect.minX + 6, y: rect.midY - 8, width: 16, height: 16))
            let colour: NSColor = isSelected && focused ? .alternateSelectedControlTextColor : .labelColor
            draw(entry.name, at: NSPoint(x: rect.minX + 28, y: rect.midY), size: 13, colour: colour,
                 centredVertically: true)
            if entry.isFolder {
                drawSymbol("chevron.right", centre: NSPoint(x: rect.maxX - 10, y: rect.midY), size: 9,
                           colour: isSelected && focused ? .alternateSelectedControlTextColor : .secondaryLabelColor)
            }
        }
    }

    /// The preview, then the file's name, kind, size and dates beneath it.
    private func drawPreview(_ image: CGImage, of entry: Entry, in context: CGContext) {
        let area = previewArea
        context.draw(image, in: area)

        var top = area.minY - 16
        top -= draw(entry.name, at: NSPoint(x: area.minX, y: top), size: 15, weight: .semibold, fromTop: true) + 4
        top -= draw("\(kind(of: entry)) – \(size(of: entry))", at: NSPoint(x: area.minX, y: top), size: 12,
                    colour: .secondaryLabelColor, fromTop: true) + 14
        NSColor.separatorColor.setFill()
        NSRect(x: area.minX, y: top, width: area.width, height: 1).fill()
        top -= 12
        top -= draw("Information", at: NSPoint(x: area.minX, y: top), size: 12, weight: .semibold, fromTop: true) + 8
        // Fixed demo dates: the picture should not carry the day it was rendered.
        for (label, value) in [("Created", "Monday 2 November 2026 at 10:14"),
                               ("Modified", "Wednesday 4 November 2026 at 09:32")] {
            draw(label, at: NSPoint(x: area.minX, y: top), size: 12, colour: .secondaryLabelColor, fromTop: true)
            top -= draw(value, at: NSPoint(x: area.maxX, y: top), size: 12, fromTop: true, alignRight: true) + 6
        }
    }

    private func kind(of entry: Entry) -> String {
        switch entry.url.pathExtension.lowercased() {
        case "step", "stp", "p21": return "STEP CAD Model"
        case "stl": return "Standard Tesselated Geometry File Format"
        case "3mf": return "3D Manufacturing Format"
        default: return "Document"
        }
    }

    /// Decimal units, as the Finder counts them, written the same way on
    /// every Mac rather than in the rendering Mac's locale.
    private func size(of entry: Entry) -> String {
        let bytes = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0f KB", Double(bytes) / 1_000) }
        return "\(bytes) bytes"
    }

    /// Draws one line of text; returns its height. `at` is the left edge (or
    /// the right edge with `alignRight`), at the line's top with `fromTop`,
    /// its middle with `centredVertically`, or its baseline area otherwise.
    @discardableResult
    private func draw(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular,
                      colour: NSColor = .labelColor, centredVertically: Bool = false,
                      fromTop: Bool = false, alignRight: Bool = false) -> CGFloat {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: colour,
        ])
        let measured = string.size()
        var origin = point
        if alignRight { origin.x -= measured.width }
        if centredVertically { origin.y -= measured.height / 2 }
        if fromTop { origin.y -= measured.height }
        string.draw(at: origin)
        return measured.height
    }
}
