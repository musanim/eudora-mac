import AppKit
import EudoraStore

/// Opens embedded/attached images (bytes already in the message) in a plain
/// native window — **no network, no web engine**. Right-clicking the image
/// offers Save As… This is the "view on demand" side of design-decisions §3.
///
/// Windows are retained here so they live until the user closes them.
@MainActor
final class ImageViewerController: NSObject, NSWindowDelegate {
    static let shared = ImageViewerController()
    private var windows: Set<NSWindow> = []

    func show(_ resource: EmbeddedImage) {
        guard let image = NSImage(data: resource.data), image.size.width > 0, image.size.height > 0 else {
            let alert = NSAlert()
            alert.messageText = "Can't display this image."
            alert.informativeText = resource.suggestedName
            alert.runModal()
            return
        }

        // Cap the initial window to 90% of the screen; the scroll view + zoom
        // handle anything larger.
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let maxW = screen.width * 0.9, maxH = screen.height * 0.9
        let natural = image.size
        let scale = min(1, min(maxW / natural.width, maxH / natural.height))
        let contentSize = NSSize(width: max(120, natural.width * scale),
                                 height: max(90, natural.height * scale))

        let imageView = SaveableImageView(resource: resource)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setFrameSize(natural)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 20
        scroll.documentView = imageView
        scroll.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = resource.suggestedName
        window.contentView = scroll
        window.isReleasedWhenClosed = false     // we manage lifetime via `windows`
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        windows.insert(window)
    }

    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow { windows.remove(w) }
    }
}

/// An image view that offers only "Save As…" on right-click.
private final class SaveableImageView: NSImageView {
    private let resource: EmbeddedImage

    init(resource: EmbeddedImage) {
        self.resource = resource
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Save As…", action: #selector(saveAs), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = resource.suggestedName
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.resource.data.write(to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
}
