// SakuraNotifications.swift — Darwin notification name constants.
// These names must match exactly between the app process and the extension process.
// The app posts them (via CFNotificationCenterGetDarwinNotifyCenter) and the
// extension observes them to know when to re-read prefs, re-scan the library, etc.

import Foundation

enum SakuraNotification {
    /// App deployed new or removed existing videos into the extension container.
    static let libraryChanged = "com.sakura.wallpaper.libraryChanged"

    /// App wrote a new sakura-prefs.json (rotation config, sync groups, etc.).
    static let prefsChanged   = "com.sakura.wallpaper.prefsChanged"

    /// Extension rotated to a new wallpaper or advanced the playlist; app should
    /// sync the current frame to the system desktop if syncDesktopWallpaper is on.
    static let stateChanged   = "com.sakura.wallpaper.stateChanged"
}
