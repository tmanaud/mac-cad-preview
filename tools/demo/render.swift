import Cocoa
import ImageIO
import Metal
import SceneKit
import UniformTypeIdentifiers

// Renders the README pictures (scripts/screenshots.sh). It runs the view
// controller Quick Look uses on the generated demo files, in a window that
// is never put on screen: nothing is read from the display, the process
// never comes to the front, and settings and caches stay in the throwaway
// home the script passes in CFFIXED_USER_HOME.
//
//   render <demo-folder> <output-folder> <light|dark>
//
// Writes frames/frame-NNNN.png (the animation), still.png (its first frame,
// for reduced motion) and one <scene>.png screenshot per demo file.

@main
enum DemoRenderer {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let theme = Theme(rawValue: arguments[3]) else {
            fail("usage: render <demo-folder> <output-folder> <light|dark>")
        }
        requireThrowawayHome()

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = theme.appearance

        let demo = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let studio = Studio(theme: theme, output: URL(fileURLWithPath: arguments[2], isDirectory: true))
        studio.recordAnimation(step: demo.appendingPathComponent("gear-pump.step"),
                               stl: demo.appendingPathComponent("vase.stl"),
                               plate: demo.appendingPathComponent("planetary-set.3mf"))
        let scenes = [("step", "gear-pump.step"), ("stl", "vase.stl"), ("3mf", "planetary-set.3mf"),
                      ("gcode", "pump-body.nc"), ("markdown", "build-notes.md"),
                      ("archive", "gear-pump-project.zip")]
        for (name, file) in scenes {
            studio.screenshot(demo.appendingPathComponent(file), name: name)
        }
    }
}

enum Theme: String {
    case light
    case dark

    var appearance: NSAppearance {
        NSAppearance(named: self == .light ? .aqua : .darkAqua)!
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("render: \(message)\n".utf8))
    exit(1)
}

/// Settings and the mesh cache live under the home folder. Recording must
/// never read or change the real ones, so refuse to run unless every such
/// path resolves inside the throwaway home.
private func requireThrowawayHome() {
    guard let fake = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !fake.isEmpty else {
        fail("CFFIXED_USER_HOME must name a throwaway folder")
    }
    let roots = [fake, URL(fileURLWithPath: fake).resolvingSymlinksInPath().path]
        .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    let paths = [NSHomeDirectory() + "/",
                 PreviewPreferences.fileURL.path,
                 FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path]
    for path in paths {
        let forms = [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
        guard forms.contains(where: { form in roots.contains { form.hasPrefix($0) } }) else {
            fail("refusing to run: settings or caches would be written outside the throwaway home")
        }
    }
}

/// Controls draw as they do in the focused Quick Look panel.
private final class HeadlessWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

private struct Pointer {
    var at: NSPoint            // in preview coordinates, origin bottom-left
    var pressed = false
}

private struct Layer {
    let image: CGImage
    let alpha: CGFloat
    let title: String
}

final class Studio {

    private let theme: Theme
    private let output: URL

    /// The preview at the size Quick Look opens it (the controller's
    /// preferredContentSize), and the panel drawn around it.
    private let content = NSSize(width: 1000, height: 750)
    private let titleBar: CGFloat = 40
    private let inset: CGFloat = 6
    private let margin: CGFloat = 40
    private let scale: CGFloat = 2
    private let fps = 30

    private let window: NSWindow
    private let renderer: SCNRenderer
    private var controller: PreviewViewController?
    private var title = ""
    private var frameNumber = 0

    init(theme: Theme, output: URL) {
        self.theme = theme
        self.output = output
        guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
        renderer = SCNRenderer(device: device, options: nil)
        window = HeadlessWindow(contentRect: NSRect(origin: .zero, size: content),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = theme.appearance
        window.isReleasedWhenClosed = false
        do {
            try FileManager.default.createDirectory(at: output.appendingPathComponent("frames"),
                                                    withIntermediateDirectories: true)
        } catch {
            fail("cannot create \(output.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private var windowRect: NSRect {
        NSRect(x: margin, y: margin,
               width: content.width + 2 * inset, height: content.height + titleBar + inset)
    }

    private var canvas: NSSize {
        NSSize(width: windowRect.width + 2 * margin, height: windowRect.height + 2 * margin)
    }

    private var well: NSRect {
        NSRect(x: margin + inset, y: margin + inset, width: content.width, height: content.height)
    }

    // MARK: - Scenes

    func recordAnimation(step: URL, stl: URL, plate: URL) {
        // Gear pump: drag to orbit, then turn the model colours off and on.
        open(step)
        let stepTitle = title
        let opening = contentImage()
        writePNG(frame([Layer(image: opening, alpha: 1, title: stepTitle)], pointer: nil),
                 to: output.appendingPathComponent("still.png"))
        hold(opening, frames: 14)
        var last = drag(from: NSPoint(x: 690, y: 430), to: NSPoint(x: 410, y: 480),
                        azimuth: -1.15, elevation: -0.10, frames: 62)
        if let box = checkboxPoint("Model colours") {
            last = movePointer(over: last, from: NSPoint(x: 410, y: 480), to: box, frames: 20)
            last = click(box, frames: 34)
            last = click(box, frames: 16)
        }

        // The vase (STL), then the planetary set (3MF), each turned by a drag.
        open(stl)
        crossfade(from: Layer(image: last, alpha: 1, title: stepTitle), toTitle: title)
        last = drag(from: NSPoint(x: 470, y: 330), to: NSPoint(x: 650, y: 360),
                    azimuth: 0.85, elevation: -0.12, frames: 56)
        hold(last, frames: 8, pointer: Pointer(at: NSPoint(x: 650, y: 360)))
        let stlTitle = title

        open(plate)
        crossfade(from: Layer(image: last, alpha: 1, title: stlTitle), toTitle: title)
        last = drag(from: NSPoint(x: 640, y: 330), to: NSPoint(x: 420, y: 350),
                    azimuth: -0.9, elevation: 0.06, frames: 56)
        hold(last, frames: 8, pointer: Pointer(at: NSPoint(x: 420, y: 350)))

        // Fade back to the opening frame, so the loop has no visible seam.
        let plateTitle = title
        for i in 1...10 {
            let t = ease(CGFloat(i) / 10)
            emit(frame([Layer(image: last, alpha: 1, title: plateTitle),
                        Layer(image: opening, alpha: t, title: stepTitle)], pointer: nil))
        }
    }

    func screenshot(_ url: URL, name: String) {
        open(url)
        writePNG(frame([Layer(image: contentImage(), alpha: 1, title: title)], pointer: nil),
                 to: output.appendingPathComponent("\(name).png"))
    }

    // MARK: - Timeline

    private func hold(_ image: CGImage, frames: Int, pointer: Pointer? = nil) {
        let still = frame([Layer(image: image, alpha: 1, title: title)], pointer: pointer)
        for _ in 0..<frames { emit(still) }
    }

    /// Orbits the camera as a drag from `from` to `to` would, pointer included.
    private func drag(from: NSPoint, to: NSPoint, azimuth: CGFloat, elevation: CGFloat,
                      frames: Int) -> CGImage {
        guard let start = sceneView?.pointOfView?.position else { fail("no camera to orbit") }
        var image = contentImage()
        for i in 1...frames {
            let t = ease(CGFloat(i) / CGFloat(frames))
            orbit(from: start, azimuth: azimuth * t, elevation: elevation * t)
            image = contentImage()
            emit(frame([Layer(image: image, alpha: 1, title: title)],
                       pointer: Pointer(at: mix(from, to, t), pressed: true)))
        }
        return image
    }

    private func movePointer(over image: CGImage, from: NSPoint, to: NSPoint, frames: Int) -> CGImage {
        for i in 1...frames {
            let t = ease(CGFloat(i) / CGFloat(frames))
            emit(frame([Layer(image: image, alpha: 1, title: title)], pointer: Pointer(at: mix(from, to, t))))
        }
        return image
    }

    private func click(_ point: NSPoint, frames: Int) -> CGImage {
        let before = contentImage()
        for _ in 0..<3 {
            emit(frame([Layer(image: before, alpha: 1, title: title)], pointer: Pointer(at: point, pressed: true)))
        }
        checkbox("Model colours")?.performClick(nil)
        let after = contentImage()
        hold(after, frames: frames, pointer: Pointer(at: point))
        return after
    }

    private func crossfade(from previous: Layer, toTitle: String) {
        let next = contentImage()
        for i in 1...10 {
            let t = ease(CGFloat(i) / 10)
            emit(frame([previous, Layer(image: next, alpha: t, title: toTitle)], pointer: nil))
        }
    }

    private func emit(_ image: CGImage) {
        frameNumber += 1
        let name = String(format: "frame-%04d.png", frameNumber)
        writePNG(image, to: output.appendingPathComponent("frames").appendingPathComponent(name))
    }

    private func ease(_ t: CGFloat) -> CGFloat {
        t * t * (3 - 2 * t)
    }

    private func mix(_ a: NSPoint, _ b: NSPoint, _ t: CGFloat) -> NSPoint {
        NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    // MARK: - Preview

    private func open(_ url: URL) {
        let controller = PreviewViewController()
        let view = controller.view
        view.frame = NSRect(origin: .zero, size: content)
        window.contentView = view
        window.setContentSize(content)
        view.layoutSubtreeIfNeeded()
        self.controller = controller
        title = url.lastPathComponent

        controller.preparePreviewOfFile(at: url) { error in
            if let error { fail("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        let deadline = Date().addingTimeInterval(120)
        while !isPresented {
            if Date() > deadline {
                let messages = descendants(NSTextField.self, of: view).map(\.stringValue).filter { !$0.isEmpty }
                fail("\(url.lastPathComponent) was not presented: \(messages.joined(separator: " | "))")
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        // The Fusion button shows only where Fusion is installed. Hide it, so
        // the pictures do not depend on the Mac that renders them.
        for button in descendants(FusionOpenButton.self, of: view) { button.isHidden = true }
        view.layoutSubtreeIfNeeded()

        // The panel shows through the clear 3D view; render that colour too,
        // so the model is drawn on exactly the well it sits in.
        if let scene = sceneView?.scene {
            var colour = NSColor.windowBackgroundColor
            theme.appearance.performAsCurrentDrawingAppearance {
                colour = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? colour
            }
            scene.background.contents = colour
        }
    }

    private var isPresented: Bool {
        guard let root = controller?.view else { return false }
        if let scene = sceneView, !scene.isHidden, scene.scene != nil { return true }
        return descendants(NSScrollView.self, of: root).contains { !$0.isHidden }
    }

    private var sceneView: CADSceneView? {
        guard let root = controller?.view else { return nil }
        return descendants(CADSceneView.self, of: root).first
    }

    private func checkbox(_ title: String) -> NSButton? {
        guard let root = controller?.view else { return nil }
        return descendants(NSButton.self, of: root).first { $0.title == title && !$0.isHidden }
    }

    /// Where the box of a checkbox is, in preview coordinates.
    private func checkboxPoint(_ title: String) -> NSPoint? {
        guard let root = controller?.view, let button = checkbox(title) else { return nil }
        return button.convert(NSPoint(x: 8, y: button.bounds.midY), to: root)
    }

    private func orbit(from start: SCNVector3, azimuth: CGFloat, elevation: CGFloat) {
        guard let camera = sceneView?.pointOfView else { return }
        var position = simd_double3(Double(start.x), Double(start.y), Double(start.z))
        position = simd_quatd(angle: Double(azimuth), axis: simd_double3(0, 1, 0)).act(position)
        let right = simd_normalize(simd_cross(simd_double3(0, 1, 0), position))
        position = simd_quatd(angle: Double(elevation), axis: right).act(position)
        camera.position = SCNVector3(position.x, position.y, position.z)
        camera.look(at: SCNVector3Zero)
    }

    private func descendants<T: NSView>(_ type: T.Type, of view: NSView) -> [T] {
        var found: [T] = []
        for child in view.subviews {
            if let match = child as? T { found.append(match) }
            found += descendants(type, of: child)
        }
        return found
    }

    // MARK: - Drawing

    /// The preview at its own size: the 3D model, then the overlay controls.
    private func contentImage() -> CGImage {
        let width = Int(content.width * scale), height = Int(content.height * scale)
        let context = bitmap(width: width, height: height)
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        if let scene = sceneView, !scene.isHidden, let world = scene.scene, let camera = scene.pointOfView {
            renderer.scene = world
            renderer.pointOfView = camera
            let image = renderer.snapshot(atTime: 0, with: full.size, antialiasingMode: .multisampling4X)
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.draw(cg, in: full)
            }
        }
        if let overlay = overlayImage() {
            context.draw(overlay, in: full)
        }
        guard let image = context.makeImage() else { fail("could not draw the preview") }
        return image
    }

    /// Everything AppKit draws over the 3D view: labels, checkboxes, text.
    private func overlayImage() -> CGImage? {
        guard let root = controller?.view else { return nil }
        let scene = sceneView
        let wasHidden = scene?.isHidden ?? true
        scene?.isHidden = true
        defer { scene?.isHidden = wasHidden }
        root.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(content.width * scale),
                                         pixelsHigh: Int(content.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = content
        root.cacheDisplay(in: root.bounds, to: rep)
        return rep.cgImage
    }

    private func frame(_ layers: [Layer], pointer: Pointer?) -> CGImage {
        let context = bitmap(width: Int(canvas.width * scale), height: Int(canvas.height * scale))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        theme.appearance.performAsCurrentDrawingAppearance {
            // Quick Look swaps the title at once; switch it halfway through a fade.
            let shown = layers.count > 1 && layers[layers.count - 1].alpha >= 0.5
                ? layers[layers.count - 1].title : layers[0].title
            drawPanel(title: shown)
            context.saveGState()
            NSBezierPath(roundedRect: well, xRadius: 7, yRadius: 7).addClip()
            for layer in layers {
                context.setAlpha(layer.alpha)
                context.draw(layer.image, in: well)
            }
            context.restoreGState()
            let border = NSBezierPath(roundedRect: well.insetBy(dx: -0.5, dy: -0.5), xRadius: 7.5, yRadius: 7.5)
            border.lineWidth = 1
            NSColor.separatorColor.setStroke()
            border.stroke()
            if let pointer { drawPointer(pointer) }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { fail("could not draw a frame") }
        return image
    }

    /// A Quick Look panel: rounded window, close and full screen buttons,
    /// the file name, and the share button.
    private func drawPanel(title: String) {
        let body = NSBezierPath(roundedRect: windowRect, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(theme == .dark ? 0.55 : 0.28)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()

        let edge = NSBezierPath(roundedRect: windowRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
        edge.lineWidth = 1
        NSColor(white: theme == .dark ? 1 : 0, alpha: theme == .dark ? 0.18 : 0.16).setStroke()
        edge.stroke()

        let middle = windowRect.maxY - titleBar / 2
        drawSymbol("xmark.circle.fill", centre: NSPoint(x: windowRect.minX + 19, y: middle))
        drawSymbol("arrow.up.left.and.arrow.down.right.circle.fill",
                   centre: NSPoint(x: windowRect.minX + 41, y: middle))
        drawSymbol("square.and.arrow.up", centre: NSPoint(x: windowRect.maxX - 22, y: middle + 1))
        let string = NSAttributedString(string: title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        string.draw(at: NSPoint(x: windowRect.minX + 60, y: middle - string.size().height / 2))
    }

    private func drawSymbol(_ name: String, centre: NSPoint) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                              width: size.width, height: size.height))
    }

    private func drawPointer(_ pointer: Pointer) {
        let point = NSPoint(x: well.minX + pointer.at.x, y: well.minY + pointer.at.y)
        if pointer.pressed {
            NSColor.systemBlue.withAlphaComponent(0.28).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)).fill()
        }
        let arrow = NSCursor.arrow
        let size = arrow.image.size
        arrow.image.draw(in: NSRect(x: point.x - arrow.hotSpot.x,
                                    y: point.y - (size.height - arrow.hotSpot.y),
                                    width: size.width, height: size.height))
    }

    private func bitmap(width: Int, height: Int) -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fail("could not allocate a \(width)×\(height) bitmap") }
        return context
    }

    private func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                1, nil) else {
            fail("cannot write \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.lastPathComponent)") }
    }
}
