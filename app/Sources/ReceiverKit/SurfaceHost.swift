import Foundation

/// SurfaceHost — rendering surface host consumed by ContainerKit.
public protocol SurfaceHost {
    associatedtype SurfaceView
    func accept(_ surface: SurfaceView)
}
