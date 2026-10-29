import AppKit

let app = NSApplication.shared
// J1: menu bar resident, no Dock icon. Enforced at runtime as well as via
// the bundle's Info.plist (LSUIElement), so the raw SwiftPM executable —
// which is launched without Info.plist during tests — keeps the same
// behaviour (no Dock icon, no app menu).
app.setActivationPolicy(.accessory)
// wave1r2 — singleton guard (YC ruling: add): if another MiragePlay instance
// is already running (same user), make a best-effort focus attempt on it and
// exit 0 before ANY UI / engine / receiver setup runs. With zero instances
// (the normal test situation) this is a silent no-op.
SingletonGuard.claimOrExit()
let delegate = AppDelegate()
app.delegate = delegate
app.run()
