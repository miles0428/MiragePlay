import Foundation

/// ReceiverState — r8-Q1 S1-S5 mapping.
/// S1: disconnected (device walked away) → background still listening
/// S2: user stopped mirroring from device → window closes, receiver stays up
/// S3: settings change → auto-restart with new config
/// S4: panel "Stop" clicked → receiver terminates (only normal stop path)
/// S5: Quit → all clean
public enum ReceiverState: Equatable {
    case idle           // Not running
    case waiting        // Running, waiting for connection
    case connected(deviceName: String)
    case stopping
}
