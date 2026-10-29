import Foundation

/// ReceiverEvent — event types emitted by ReceiverController.
public enum ReceiverEvent: Equatable {
    case connected(deviceName: String)
    case disconnected
    case error(message: String)

    /// wave1r4 (trust increment I1) — uxplay completed a PIN pairing and wrote the registry
    /// (`registered new client: <name> DeviceID = <machine code> PK = ` plus the pk64 continuation;
    /// uxplay.cpp:2624). This event fires only while the PIN is on and only when a PIN
    /// was entered successfully and pairing completed — a code-free reconnect does not trigger it
    /// (an already-trusted device does not trigger it; every connection that was not trusted pairs again and triggers it again). The semantics are "should this device be trusted (remembered)?" — the **trigger source** (unrelated to connectivity).
    case trustPairingRegistered(deviceName: String, deviceID: String)
}
