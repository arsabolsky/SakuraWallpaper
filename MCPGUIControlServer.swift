import Cocoa

final class MCPGUIControlServer {
    private weak var wallpaperManager: WallpaperManager?
    private var port: CFMessagePort?
    private var runLoopSource: CFRunLoopSource?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(wallpaperManager: WallpaperManager) {
        self.wallpaperManager = wallpaperManager
    }

    func start() {
        stop()

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var cfContext = CFMessagePortContext(
            version: 0,
            info: context,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        var shouldFreeInfo: DarwinBoolean = false
        guard let port = CFMessagePortCreateLocal(
            nil,
            MCPControlChannel.messagePortName as CFString,
            MCPGUIControlServer.handleMessage,
            &cfContext,
            &shouldFreeInfo
        ) else {
            return
        }

        self.port = port
        runLoopSource = CFMessagePortCreateRunLoopSource(nil, port, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let port {
            CFMessagePortInvalidate(port)
        }
        runLoopSource = nil
        port = nil
    }

    deinit {
        stop()
    }

    private static let handleMessage: CFMessagePortCallBack = { _, _, data, info in
        guard let info else { return nil }
        let server = Unmanaged<MCPGUIControlServer>.fromOpaque(info).takeUnretainedValue()
        guard let response = server.handle(data: data as Data?) else { return nil }
        return Unmanaged.passRetained(response as CFData)
    }

    private func handle(data: Data?) -> Data? {
        guard let data else {
            return encode(MCPControlResponse(errorMessage: "Missing request data"))
        }

        do {
            let request = try decoder.decode(MCPControlRequest.self, from: data)
            let result = try handle(request)
            return encode(MCPControlResponse(result: result))
        } catch let error as MCPGUIControlError {
            return encode(MCPControlResponse(errorMessage: error.message))
        } catch {
            return encode(MCPControlResponse(errorMessage: error.localizedDescription))
        }
    }

    private func encode(_ response: MCPControlResponse) -> Data? {
        try? encoder.encode(response)
    }

    private func handle(_ request: MCPControlRequest) throws -> MCPControlValue {
        guard let wallpaperManager else {
            throw MCPGUIControlError(message: "Wallpaper engine unavailable")
        }

        switch request.toolName {
        case "set_wallpaper":
            return try setWallpaper(arguments: request.arguments, wallpaperManager: wallpaperManager)
        case "set_folder":
            return try setFolder(arguments: request.arguments, wallpaperManager: wallpaperManager)
        case "stop_wallpaper":
            return try stopWallpaper(arguments: request.arguments, wallpaperManager: wallpaperManager)
        case "pause_resume":
            return try pauseResume(arguments: request.arguments, wallpaperManager: wallpaperManager)
        case "next_wallpaper":
            return try nextWallpaper(arguments: request.arguments, wallpaperManager: wallpaperManager)
        case "get_status":
            return getStatus(arguments: request.arguments, wallpaperManager: wallpaperManager)
        case "get_settings":
            return getSettings(arguments: request.arguments)
        case "update_settings":
            return try updateSettings(arguments: request.arguments, wallpaperManager: wallpaperManager)
        default:
            throw MCPGUIControlError(message: "Unsupported GUI forwarded tool: \(request.toolName)")
        }
    }

    private func setWallpaper(arguments: [String: MCPControlValue], wallpaperManager: WallpaperManager) throws -> MCPControlValue {
        guard let filePath = arguments["file_path"]?.stringValue, !filePath.isEmpty else {
            throw MCPGUIControlError(message: "file_path is required and must be non-empty")
        }

        let url = URL(fileURLWithPath: filePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir) else {
            throw MCPGUIControlError(message: "File not found: \(filePath)")
        }
        guard !isDir.boolValue else {
            throw MCPGUIControlError(message: "Path is a directory, not a file. Use set_folder for folders.")
        }
        guard MediaType.detect(url) != .unsupported else {
            throw MCPGUIControlError(message: "Unsupported file format. Supported: mp4, mov, gif, m4v, png, jpg, jpeg, heic, webp, bmp, tiff")
        }

        if let screen = screen(from: arguments) {
            wallpaperManager.setWallpaper(url: url, for: screen)
        } else {
            for screen in NSScreen.screens {
                wallpaperManager.setWallpaper(url: url, for: screen)
            }
        }

        return .object(["success": .bool(true), "file_path": .string(filePath)])
    }

    private func setFolder(arguments: [String: MCPControlValue], wallpaperManager: WallpaperManager) throws -> MCPControlValue {
        guard let folderPath = arguments["folder_path"]?.stringValue, !folderPath.isEmpty else {
            throw MCPGUIControlError(message: "folder_path is required")
        }

        let folderURL = URL(fileURLWithPath: folderPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
            throw MCPGUIControlError(message: "Folder not found or not a directory: \(folderPath)")
        }

        let interval = arguments["rotation_interval_minutes"]?.numberValue.map { max(1, Int($0)) } ?? 15
        let shuffle = arguments["shuffle"]?.boolValue ?? false
        let includeSubfolders = arguments["include_subfolders"]?.boolValue ?? false
        let fitMode = arguments["fit_mode"]?.stringValue.flatMap(WallpaperFitMode.init) ?? .fill
        let config = Screen_Config(
            folderPath: folderPath,
            wallpaperPath: nil,
            rotationIntervalMinutes: interval,
            isShuffleMode: shuffle,
            isRotationEnabled: true,
            includeSubfolders: includeSubfolders,
            isFolderMode: true,
            isSynced: NSScreen.screens.count > 1,
            wallpaperFit: fitMode
        )

        if let screen = screen(from: arguments) {
            wallpaperManager.setFolder(url: folderURL, for: screen, config: config)
        } else {
            for screen in NSScreen.screens {
                wallpaperManager.setFolder(url: folderURL, for: screen, config: config)
            }
        }

        let fileCount = (try? PlaylistBuilder.collectMediaFiles(in: folderURL, includeSubfolders: includeSubfolders).count) ?? 0
        return .object([
            "success": .bool(true),
            "folder_path": .string(folderPath),
            "file_count": .number(Double(fileCount))
        ])
    }

    private func stopWallpaper(arguments: [String: MCPControlValue], wallpaperManager: WallpaperManager) throws -> MCPControlValue {
        var stopped: [String] = []
        if let screen = screen(from: arguments) {
            let id = SettingsManager.screenIdentifier(screen)
            wallpaperManager.stopWallpaper(for: screen)
            stopped = [id]
        } else {
            stopped = NSScreen.screens.map { SettingsManager.screenIdentifier($0) }
            wallpaperManager.stopAll()
        }

        return .object([
            "success": .bool(true),
            "stopped_screens": .array(stopped.map { .string($0) })
        ])
    }

    private func pauseResume(arguments: [String: MCPControlValue], wallpaperManager: WallpaperManager) throws -> MCPControlValue {
        guard let action = arguments["action"]?.stringValue else {
            throw MCPGUIControlError(message: "action is required: 'pause', 'resume', or 'toggle'")
        }

        switch action {
        case "pause":
            wallpaperManager.isPaused = true
            wallpaperManager.checkPlaybackState()
        case "resume":
            wallpaperManager.isPaused = false
            wallpaperManager.checkPlaybackState()
        case "toggle":
            wallpaperManager.isPaused.toggle()
            wallpaperManager.checkPlaybackState()
        default:
            throw MCPGUIControlError(message: "Invalid action: '\(action)'. Use 'pause', 'resume', or 'toggle'.")
        }

        return .object(["paused": .bool(wallpaperManager.isPaused)])
    }

    private func nextWallpaper(arguments: [String: MCPControlValue], wallpaperManager: WallpaperManager) throws -> MCPControlValue {
        var results: [[String: MCPControlValue]] = []
        if let screen = screen(from: arguments) {
            let id = SettingsManager.screenIdentifier(screen)
            wallpaperManager.nextWallpaper(for: screen)
            results.append(["id": .string(id), "new_file": .string(wallpaperManager.currentFiles[id]?.path ?? "")])
        } else {
            wallpaperManager.nextWallpaper()
            for screen in NSScreen.screens {
                let id = SettingsManager.screenIdentifier(screen)
                results.append(["id": .string(id), "new_file": .string(wallpaperManager.currentFiles[id]?.path ?? "")])
            }
        }

        return .object([
            "success": .bool(true),
            "results": .array(results.map { .object($0) })
        ])
    }

    private func getStatus(arguments: [String: MCPControlValue], wallpaperManager: WallpaperManager) -> MCPControlValue {
        let targetID = arguments["screen_id"]?.stringValue
        let screens = NSScreen.screens.filter {
            targetID == nil || SettingsManager.screenIdentifier($0) == targetID
        }

        let entries = screens.map { screen -> MCPControlValue in
            let id = SettingsManager.screenIdentifier(screen)
            let config = SettingsManager.shared.screenConfig(for: id)
            var entry: [String: MCPControlValue] = [
                "id": .string(id),
                "name": .string(screen.localizedName),
                "is_playing": .bool(wallpaperManager.currentFiles[id] != nil),
                "is_paused": .bool(wallpaperManager.isPaused),
                "is_folder_mode": .bool(config.isFolderMode),
                "rotation_interval_minutes": .number(Double(config.rotationIntervalMinutes)),
                "shuffle": .bool(config.isShuffleMode),
                "include_subfolders": .bool(config.includeSubfolders),
                "fit_mode": .string(config.wallpaperFit.rawValue)
            ]
            if let current = wallpaperManager.currentFiles[id]?.path { entry["current_file"] = .string(current) }
            if let folder = config.folderPath { entry["folder_path"] = .string(folder) }
            if let wallpaper = config.wallpaperPath { entry["wallpaper_path"] = .string(wallpaper) }
            return .object(entry)
        }

        return .object(["screens": .array(entries)])
    }

    private func getSettings(arguments: [String: MCPControlValue]) -> MCPControlValue {
        let targetID = arguments["screen_id"]?.stringValue
        let entries = NSScreen.screens
            .filter { targetID == nil || SettingsManager.screenIdentifier($0) == targetID }
            .map { screen -> MCPControlValue in
                let id = SettingsManager.screenIdentifier(screen)
                let config = SettingsManager.shared.screenConfig(for: id)
                var entry: [String: MCPControlValue] = [
                    "id": .string(id),
                    "name": .string(screen.localizedName),
                    "rotation_interval_minutes": .number(Double(config.rotationIntervalMinutes)),
                    "shuffle": .bool(config.isShuffleMode),
                    "rotation_enabled": .bool(config.isRotationEnabled),
                    "include_subfolders": .bool(config.includeSubfolders),
                    "is_folder_mode": .bool(config.isFolderMode),
                    "is_synced": .bool(config.isSynced),
                    "fit_mode": .string(config.wallpaperFit.rawValue)
                ]
                if let folder = config.folderPath { entry["folder_path"] = .string(folder) }
                if let wallpaper = config.wallpaperPath { entry["wallpaper_path"] = .string(wallpaper) }
                return .object(entry)
            }

        return .object(["screens": .array(entries)])
    }

    private func updateSettings(arguments: [String: MCPControlValue], wallpaperManager: WallpaperManager) throws -> MCPControlValue {
        let targetID = arguments["screen_id"]?.stringValue
        var updatedFields: [String] = []

        func apply(to id: String) {
            var config = SettingsManager.shared.screenConfig(for: id)
            if let value = arguments["rotation_interval_minutes"]?.numberValue {
                config.rotationIntervalMinutes = max(1, Int(value))
                updatedFields.append("rotation_interval_minutes")
            }
            if let value = arguments["shuffle"]?.boolValue {
                config.isShuffleMode = value
                updatedFields.append("shuffle")
            }
            if let value = arguments["rotation_enabled"]?.boolValue {
                config.isRotationEnabled = value
                updatedFields.append("rotation_enabled")
            }
            if let value = arguments["include_subfolders"]?.boolValue {
                config.includeSubfolders = value
                updatedFields.append("include_subfolders")
                if let folderPath = config.folderPath,
                   let screen = NSScreen.screens.first(where: { SettingsManager.screenIdentifier($0) == id }) {
                    wallpaperManager.setFolder(url: URL(fileURLWithPath: folderPath), for: screen, config: config)
                    return
                }
            }
            if let value = arguments["fit_mode"]?.stringValue, let fitMode = WallpaperFitMode(rawValue: value) {
                config.wallpaperFit = fitMode
                updatedFields.append("fit_mode")
            }
            if let value = arguments["is_synced"]?.boolValue {
                config.isSynced = value
                updatedFields.append("is_synced")
            }
            SettingsManager.shared.setScreenConfig(config, for: id)
        }

        if let targetID {
            guard NSScreen.screens.contains(where: { SettingsManager.screenIdentifier($0) == targetID }) else {
                throw MCPGUIControlError(message: "Screen not found: \(targetID)")
            }
            apply(to: targetID)
        } else {
            for screen in NSScreen.screens {
                apply(to: SettingsManager.screenIdentifier(screen))
            }
        }

        return .object([
            "success": .bool(true),
            "updated_fields": .array(updatedFields.map { .string($0) })
        ])
    }

    private func screen(from arguments: [String: MCPControlValue]) -> NSScreen? {
        guard let targetID = arguments["screen_id"]?.stringValue else { return nil }
        return NSScreen.screens.first { SettingsManager.screenIdentifier($0) == targetID }
    }
}

private struct MCPGUIControlError: Error {
    let message: String
}
