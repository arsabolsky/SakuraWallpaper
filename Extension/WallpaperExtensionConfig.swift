// WallpaperExtensionConfig.swift — XPC connection configuration for the wallpaper extension.
// Adapted from PhospheneExtension/WallpaperExtensionConfig.swift.
// Changes: WallpaperXPCHandler → SakuraXPCHandler, WallpaperState → SakuraExtensionState.

import ExtensionFoundation
import Foundation

struct WallpaperExtensionConfig: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        extensionLog("XPC from PID=\(connection.processIdentifier)")

        // Validate the caller before exporting the handler or resuming.
        // An unexpected (non-Apple) process never reaches our exported methods.
        guard CallerValidation.isAcceptable(connection) else {
            extensionLog("XPC rejected: untrusted caller")
            return false
        }

        let exported = NSXPCInterface(with: (any WallpaperExtensionXPCProtocol).self)

        // Build class whitelist from runtime-loaded WallpaperExtensionKit classes.
        // Private API: these class names must match what dlopen registered after loading
        // WallpaperExtensionKit. If any are missing, XPC argument decoding for that
        // class will fail silently on calls that use it.
        let typeNames = [
            "WallpaperIDXPC",
            "WallpaperCreationRequestXPC",
            "WallpaperUpdateRequestXPC",
            "WallpaperRemoteContextXPC",
            "WallpaperSnapshotXPC",
            "WallpaperContentTypeSetXPC",
            "WallpaperChoiceIDXPC",
            "WallpaperChoiceIDsXPC",
            "WallpaperExtensionChoiceRequestXPC",
            "WallpaperChoiceRequestAdditionResultXPC",
            "WallpaperDebugRequestXPC",
            "WallpaperDebugResponseXPC",
            "WallpaperMigrationVersionXPC",
            "WallpaperSettingsViewModelsXPC",
            "AuditTokenXPC",
        ]

        let allTypes = NSMutableSet()
        var missing: [String] = []
        for name in typeNames {
            if let cls = objc_getClass(name) {
                allTypes.add(cls)
            } else {
                missing.append(name)
            }
        }
        if !missing.isEmpty {
            extensionLog("  MISSING XPC types (may cause silent decode failures): \(missing.joined(separator: ", "))")
        }
        allTypes.add(NSString.self)
        allTypes.add(NSNumber.self)
        allTypes.add(NSData.self)
        allTypes.add(NSArray.self)
        allTypes.add(NSDictionary.self)
        allTypes.add(NSURL.self)
        allTypes.add(NSError.self)

        let classes = allTypes as! Set<AnyHashable>

        // Register the full set of allowed types for each protocol method argument.
        // Indices and isReply flags copied verbatim from Phosphene — they describe
        // the exact position of each XPC object in the protocol's method signatures.
        let selectors: [(Selector, Int, Bool)] = [
            (#selector(SakuraXPCHandler.acquire(withId:request:reply:)), 0, false),
            (#selector(SakuraXPCHandler.acquire(withId:request:reply:)), 1, false),
            (#selector(SakuraXPCHandler.acquire(withId:request:reply:)), 0, true),
            (#selector(SakuraXPCHandler.update(withId:request:reply:)), 0, false),
            (#selector(SakuraXPCHandler.update(withId:request:reply:)), 1, false),
            (#selector(SakuraXPCHandler.invalidate(withId:reply:)), 0, false),
            (#selector(SakuraXPCHandler.snapshot(withId:reply:)), 0, false),
            (#selector(SakuraXPCHandler.snapshot(withId:reply:)), 0, true),
            (#selector(SakuraXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, false),
            (#selector(SakuraXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, true),
            (#selector(SakuraXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, false),
            (#selector(SakuraXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 1, false),
            (#selector(SakuraXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, true),
            (#selector(SakuraXPCHandler.removeChoiceRequest(withChoiceRequest:reply:)), 0, false),
            (#selector(SakuraXPCHandler.selectedChoicesDidChange(for:reply:)), 0, false),
            (#selector(SakuraXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 0, false),
            (#selector(SakuraXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 1, false),
            (#selector(SakuraXPCHandler.isChoiceDownloaded(with:reply:)), 0, false),
            (#selector(SakuraXPCHandler.download(withChoiceID:reply:)), 0, false),
            (#selector(SakuraXPCHandler.pauseDownload(for:reply:)), 0, false),
            (#selector(SakuraXPCHandler.cancelDownload(for:reply:)), 0, false),
            (#selector(SakuraXPCHandler.resumeDownload(for:reply:)), 0, false),
            (#selector(SakuraXPCHandler.removeDownload(for:reply:)), 0, false),
            (#selector(SakuraXPCHandler.migrateSelectedChoice(for:reply:)), 0, false),
            (#selector(SakuraXPCHandler.migrateSelectedChoice(for:reply:)), 0, true),
            (#selector(SakuraXPCHandler.migrate(from:to:reply:)), 0, false),
            (#selector(SakuraXPCHandler.migrate(from:to:reply:)), 1, false),
            (#selector(SakuraXPCHandler.skipShuffledContent(withId:reply:)), 0, false),
            (#selector(SakuraXPCHandler.canSkipShuffledContent(withId:reply:)), 0, false),
            (#selector(SakuraXPCHandler.handleDebugRequest(for:reply:)), 0, false),
            (#selector(SakuraXPCHandler.handleDebugRequest(for:reply:)), 0, true),
            (#selector(SakuraXPCHandler.handleNotification(withNamed:reply:)), 0, false),
        ]

        for (sel, idx, isReply) in selectors {
            exported.setClasses(classes, for: sel, argumentIndex: idx, ofReply: isReply)
        }

        connection.exportedInterface = exported
        connection.remoteObjectInterface = NSXPCInterface(with: (any WallpaperExtensionProxyXPCProtocol).self)

        let handler = SakuraXPCHandler()
        connection.exportedObject = handler

        connection.interruptionHandler = { extensionLog("XPC interrupted") }

        connection.invalidationHandler = { [weak handler] in
            handler?.agentProxy = nil
            let liveCount = SakuraExtensionState.shared.activeContextCount
            SakuraExtensionState.shared.removeAllContexts()
            guard liveCount > 0 else {
                // Benign teardown: no live contexts (settings-only connection, or already inactive).
                extensionLog("XPC invalidated")
                return
            }
            // Abnormal path: the host connection died while live rendering contexts exist.
            // Deep standby / hibernation can tear the connection after hours asleep. The
            // wallpaper keeps compositing a dead surface, leaving the desktop grey/black.
            // Normal teardown arrives as invalidate(withId:) so liveCount is 0 there.
            // Exiting here forces the framework to relaunch the extension and re-acquire
            // every display — the empirically verified recovery path (see Phosphene #2).
            extensionLog("XPC invalidated mid-render — freed \(liveCount) context(s); exiting to force re-acquire")
            exit(0)
        }

        connection.resume()

        handler.agentProxy = connection.remoteObjectProxy as? (any WallpaperExtensionProxyXPCProtocol)

        extensionLog("XPC accepted")
        return true
    }
}
