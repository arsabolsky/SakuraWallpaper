import Foundation

public enum WallpaperFitMode: String, Codable, CaseIterable {
    case fill
    case fit
    case stretch
}

// MARK: - Screen_Config

public struct Screen_Config: Codable, Equatable {
    public var folderPath: String?
    public var wallpaperPath: String?
    public var rotationIntervalMinutes: Int
    public var isShuffleMode: Bool
    public var isRotationEnabled: Bool
    public var includeSubfolders: Bool
    public var isFolderMode: Bool
    public var isSynced: Bool
    public var wallpaperFit: WallpaperFitMode
    public var isFolderBrowserVisible: Bool
    public var securityScopedBookmark: Data?

    public static let `default` = Screen_Config(
        folderPath: nil,
        wallpaperPath: nil,
        rotationIntervalMinutes: 15,
        isShuffleMode: false,
        isRotationEnabled: true,
        includeSubfolders: false,
        isFolderMode: false,
        isSynced: true,
        wallpaperFit: .fill,
        isFolderBrowserVisible: false
    )

    public enum CodingKeys: String, CodingKey {
        case folderPath              = "folder_path"
        case wallpaperPath           = "wallpaper_path"
        case rotationIntervalMinutes = "rotation_interval_minutes"
        case isShuffleMode           = "is_shuffle_mode"
        case isRotationEnabled       = "is_rotation_enabled"
        case includeSubfolders       = "include_subfolders"
        case isFolderMode            = "is_folder_mode"
        case isSynced                = "is_synced"
        case wallpaperFit            = "wallpaper_fit"
        case isFolderBrowserVisible  = "is_folder_browser_visible"
        case securityScopedBookmark  = "security_scoped_bookmark"
    }

    public init(
        folderPath: String?,
        wallpaperPath: String?,
        rotationIntervalMinutes: Int,
        isShuffleMode: Bool,
        isRotationEnabled: Bool,
        includeSubfolders: Bool,
        isFolderMode: Bool,
        isSynced: Bool,
        wallpaperFit: WallpaperFitMode = .fill,
        isFolderBrowserVisible: Bool = false,
        securityScopedBookmark: Data? = nil
    ) {
        self.folderPath = folderPath
        self.wallpaperPath = wallpaperPath
        self.rotationIntervalMinutes = rotationIntervalMinutes
        self.isShuffleMode = isShuffleMode
        self.isRotationEnabled = isRotationEnabled
        self.includeSubfolders = includeSubfolders
        self.isFolderMode = isFolderMode
        self.isSynced = isSynced
        self.wallpaperFit = wallpaperFit
        self.isFolderBrowserVisible = isFolderBrowserVisible
        self.securityScopedBookmark = securityScopedBookmark
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = Screen_Config.default
        folderPath              = try container.decodeIfPresent(String.self, forKey: .folderPath)              ?? d.folderPath
        wallpaperPath           = try container.decodeIfPresent(String.self, forKey: .wallpaperPath)           ?? d.wallpaperPath
        rotationIntervalMinutes = try container.decodeIfPresent(Int.self,    forKey: .rotationIntervalMinutes) ?? d.rotationIntervalMinutes
        isShuffleMode           = try container.decodeIfPresent(Bool.self,   forKey: .isShuffleMode)           ?? d.isShuffleMode
        isRotationEnabled       = try container.decodeIfPresent(Bool.self,   forKey: .isRotationEnabled)       ?? d.isRotationEnabled
        includeSubfolders       = try container.decodeIfPresent(Bool.self,   forKey: .includeSubfolders)       ?? d.includeSubfolders
        isFolderMode            = try container.decodeIfPresent(Bool.self,   forKey: .isFolderMode)            ?? d.isFolderMode
        isSynced                = try container.decodeIfPresent(Bool.self,   forKey: .isSynced)                ?? d.isSynced
        if let rawWallpaperFit = try container.decodeIfPresent(String.self, forKey: .wallpaperFit),
           let wallpaperFitMode = WallpaperFitMode(rawValue: rawWallpaperFit) {
            wallpaperFit = wallpaperFitMode
        } else {
            wallpaperFit = d.wallpaperFit
        }
        isFolderBrowserVisible = try container.decodeIfPresent(Bool.self, forKey: .isFolderBrowserVisible) ?? d.isFolderBrowserVisible
        securityScopedBookmark = try container.decodeIfPresent(Data.self, forKey: .securityScopedBookmark) ?? d.securityScopedBookmark
    }
}

// MARK: - Screen_Registry

public typealias Screen_Registry = [String: Screen_Config]

// MARK: - New_Screen_Policy

public enum New_Screen_Policy: String, Codable {
    case inheritSyncGroup
    case blank
}
