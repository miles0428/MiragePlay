import Foundation
import Localization
import ReceiverKit

/// SessionNotifier — J3-5b ⑪ connection notification (the smallest responsibility unit; BLUEPRINT arch-3 #7).
///
/// The event CONTAINER: connect/disconnect events come in, get translated to
/// notifications (texts via `SessionNotificationTemplates`), and are
/// dispatched to subscribers (subscribe/dispatch). It does nothing else — no log
/// parsing (events arrive typed from the receiver, IF-1 `events` =
/// as the single event source), no restart decisions, no windows, and per SRP-5 it holds NO
/// configuration state at all (no config reads, no delivery gate).
///
/// D8 (YC ruling B "only remove the UI switch"): the settings-page switch was withdrawn, so
/// the persisted B2 slot no longer controls delivery. Dispatch is
/// UNCONDITIONAL — every connect/disconnect event reaches every subscriber
/// and its NOTIFY trace is written to `ui.log` whatever the persisted B2
/// value happens to be (recording is unconditional; an old settings file with false is written as-is). The B2 value
/// survives in the ⑫ model as a reserved, inert field; this unit never
/// consults it.
///
/// stage G (wave1g): the texts are rendered through the injected
/// `LanguageService` at DISPATCH time — the language in force when the
/// notification fires wins (instant switchover; the next dispatch uses the new language). The service is a
/// lookup service (never configuration state; the B3 truth lives in the
/// engine — SRP-5 intact).
///
/// Form is deliberately undecided: the contract reserves BOTH states
/// (contract L396 "reserve two structural forms: fire a notification or only update the status-row subscriber"; R5-Q1 pending).
/// The current fallback (R5 undecided) delivers to the
/// the panel status-row subscriber path — the AppShell subscribes
/// `StatusItemMenu.presentSessionNotification`; the panel status ROW itself
/// keeps being maintained by the coordinator state chain (state ≠ notification), so a
/// subscription concern can never affect the status display.
/// When R5 settles, the banner/panel form lands as an additional subscriber
/// here — no structural change.
///
/// Main-thread only (menu-bar app, same discipline as the other units).
public final class SessionNotifier {

    /// One connection-session notification, ready for presentation.
    public struct Notification: Equatable {

        public enum Kind: Equatable {
            case connected
            case disconnected
        }

        /// Event family this notification was translated from.
        public let kind: Kind

        /// Device name for `.connected`; nil for `.disconnected`.
        public let deviceName: String?

        /// The rendered text (Templates; the fallback value = same source as the panel strings to begin with).
        public let message: String

        public init(kind: Kind, deviceName: String?, message: String) {
            self.kind = kind
            self.deviceName = deviceName
            self.message = message
        }
    }

    /// Subscriber callback type (called on the main thread).
    public typealias Subscriber = (Notification) -> Void

    /// stage G: the term lookup behind the notification texts (resolved at dispatch time
    /// rendering — the language in force when the notification fires wins).
    /// `nil` = not wired; the templates then render the term key (the same
    /// honest convention as a missing dictionary).
    public var localization: LanguageService?

    private var subscribers: [(token: UInt64, handler: Subscriber)] = []
    private var nextToken: UInt64 = 1

    public init() {}

    // MARK: - Subscription

    /// Registers a subscriber. The fallback status-row subscriber never
    /// unsubscribes (a long-lived carrier — there is no public teardown seam; the lifecycle is
    /// tied to the notifier's own deinit).
    @discardableResult
    public func subscribe(_ handler: @escaping Subscriber) -> UInt64 {
        let token = nextToken
        nextToken += 1
        subscribers.append((token: token, handler: handler))
        return token
    }

    // MARK: - Event intake (the event container's entry point)

    /// Feeds one receiver event from the single event source (IF-1 `events`,
    /// funnelled through the coordinator). `.error` is deliberately NOT a
    /// notification — the failure-message channel = the panel status-row short reason (R4-Q2=A), not ⑪.
    /// wave1r4: `.trustPairingRegistered` is NOT a ⑪ notification either —
    /// the trust ask runs on its own prompt channel (AppShell decision
    /// layer), gated by the PIN state — the retired B2 slot plays no part.
    public func handle(_ event: ReceiverEvent) {
        switch event {
        case .connected(let deviceName):
            notifyConnected(device: deviceName)
        case .disconnected:
            notifyDisconnected()
        case .error:
            break
        case .trustPairingRegistered:
            break
        }
    }

    /// Reported a device connected.
    func notifyConnected(device: String) {
        dispatch(Notification(
            kind: .connected,
            deviceName: device,
            message: SessionNotificationTemplates.connected(device: device, localization: localization)
        ))
    }

    /// Reported the device disconnected.
    func notifyDisconnected() {
        dispatch(Notification(
            kind: .disconnected,
            deviceName: nil,
            message: SessionNotificationTemplates.disconnected(localization: localization)
        ))
    }

    // MARK: - Dispatch (unconditional)

    /// Delivers to every subscriber — UNCONDITIONALLY. D8: no configuration
    /// is consulted here, so every event is dispatched and traced whatever
    /// the persisted B2 value says (recording is unaffected by the setting).
    private func dispatch(_ notification: Notification) {
        for subscriber in subscribers {
            subscriber.handler(notification)
        }
    }
}
