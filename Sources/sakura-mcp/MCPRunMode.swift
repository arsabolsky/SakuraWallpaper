import Foundation

enum MCPRunMode: Equatable {
    case forwardToGUI
    case standalone
    case rejectDuplicate
    case noGUI

    static func resolve(hasGUI: Bool, guiEndpointAvailable: Bool, acquiredStandaloneLock: Bool) -> MCPRunMode {
        guard hasGUI else { return .noGUI }
        if guiEndpointAvailable { return .forwardToGUI }
        if acquiredStandaloneLock { return .standalone }
        return .rejectDuplicate
    }
}

final class MCPSingleInstanceLock {
    private let lockURL: URL
    private var descriptor: Int32 = -1

    init(lockURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("sakura-mcp-standalone.lock")) {
        self.lockURL = lockURL
    }

    func acquire() -> Bool {
        descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}
