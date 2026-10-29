import AppKit

/// Mirror window controller: show/hide/F/double-click fullscreen.
final class MirrorWindowController {

    private var window: NSWindow?
    private var contentView: NSView?

    func show() {
        guard let w = window else {
            createWindow()
            window?.makeKeyAndOrderFront(nil)
            return
        }
        w.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    func attachSurface(_ surface: Any) {
        // Stage2: native-macos-renderer surface attachment
    }

    private func createWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "MiragePlay"
        w.center()
        w.isReleasedWhenClosed = false

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        cv.wantsLayer = true
        cv.layer?.backgroundColor = NSColor.black.cgColor
        w.contentView = cv
        self.contentView = cv
        self.window = w

        // F key = fullscreen
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 3 { // F key
                self?.window?.toggleFullScreen(nil)
            }
            return event
        }
    }
}
