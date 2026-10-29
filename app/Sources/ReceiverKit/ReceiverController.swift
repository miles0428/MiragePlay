import Foundation
import SharedTypes

/// IF-1: ReceiverController protocol — the single interface between shell and core.
/// start(snapshot:)/stop()/restart(snapshot:) — E1 auto-restart semantics.
public protocol ReceiverController {
    func start(snapshot: EffectiveSnapshot)
    func stop()
    func restart(snapshot: EffectiveSnapshot)
    var state: ReceiverState { get }
    var events: AsyncStream<ReceiverEvent> { get }
    func attachSurface(to host: any SurfaceHost)

    /// wave1r6 (trust timing fix) — the number of LIVE client connections at the
    /// SOCKET level (`Accepted … on socket N` minus `Connection closed …`).
    /// The trust-apply gate reads this before restarting the receiver: a restart
    /// while another device is still projecting would kick that device's
    /// session (another device online must not be kicked). A new spawn starts from zero (a new generation has no connections).
    var liveConnectionCount: Int { get }
}
