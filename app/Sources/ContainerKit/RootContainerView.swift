import AppKit
import ReceiverKit

/// Root container view managing the mirror window.
public final class RootContainerView {
    private var mirrorWindowController: MirrorWindowController?
    public init() {
        mirrorWindowController = MirrorWindowController()
    }
    public func showMirrorWindow() { mirrorWindowController?.show() }
    public func hideMirrorWindow() { mirrorWindowController?.hide() }
    public func attachSurface(_ surface: Any) {}
}
