// SakuraXPCHandler.swift — XPC handler implementing WallpaperExtensionXPCProtocol.
// Phase 5: acquire, update, invalidate, snapshot, and selectedChoicesDidChange are fully wired.
//
// acquire() design (one-shot reply):
//   1. Mirror-extract display geometry, choice, and cache URL from the private XPC request objects.
//   2. Create a remote CAContext and store a placeholder SakuraContext (renderer = nil).
//   3. Set rootLayer.contents from the BMP cache immediately so the display is never blank.
//   4. Reply immediately so WallpaperAgent isn't blocked waiting for renderer startup.
//   5. Spawn a detached Task to create the SakuraRenderer (≥500ms after reply, 5s safety timeout).
//   6. On renderer creation: wire variantSelector, start RotationEngine, update stored context.
//
// The Mirror-reflection blocks are copied from PhospheneExtension/WallpaperXPCHandler.swift.
// WallpaperExtensionKit field names are OS-level constants identical across all extension types.

import AppKit
import AVFoundation
import CoreMedia
import os
import QuartzCore

final class SakuraXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    /// Proxy to call methods on WallpaperAgent (ping, invalidateSnapshots, etc.).
    var agentProxy: (any WallpaperExtensionProxyXPCProtocol)?

    // MARK: - acquire

    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extensionLog("=== ACQUIRE ===")

        // --- Mirror extraction block — copied from PhospheneExtension/WallpaperXPCHandler.swift ---
        // WallpaperCreationRequestXPC fields are not in the public SDK; we read them via
        // Mirror reflection. Each access is guarded: if Apple renames a field, the guard
        // returns nil / the fallback fires and we log a warning rather than crashing.

        // Extract WallpaperID UUID (used for cleanup in invalidate and update).
        var wallpaperIDString: String?
        if let idObj = id as? NSObject {
            let idStr = String(describing: Mirror(reflecting: idObj).children.first?.value ?? "")
            // Private field: the UUID string inside WallpaperIDXPC.
            // If this returns nil the extension will silently be unable to invalidate this context by ID.
            if let range = idStr.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}",
                                       options: .regularExpression) {
                wallpaperIDString = String(idStr[range])
            }
        }
        if wallpaperIDString == nil {
            extensionLog("  WARNING: Could not extract wallpaperID — context will not be individually removable")
        }

        // Extract destination size, scale, displayID, and cacheDirectory.
        var destSize = CGSize(width: 2_560, height: 1_440) // safe fallback
        var scaleFactor: CGFloat = 2.0
        var isPreview = false
        var displayID: UInt32?
        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            for child in mirror.children {
                let reqMirror = Mirror(reflecting: child.value)
                for prop in reqMirror.children {
                    if prop.label == "destination" {
                        // Private field: "destination" contains size, scaleFactor, directDisplayID.
                        // If this returns nil the extension will silently receive no render context.
                        let destMirror = Mirror(reflecting: prop.value)
                        for destProp in destMirror.children {
                            if destProp.label == "size", let size = destProp.value as? CGSize {
                                destSize = size
                            } else if destProp.label == "scaleFactor", let sf = destProp.value as? CGFloat {
                                scaleFactor = sf
                            } else if destProp.label == "directDisplayID", let did = destProp.value as? UInt32 {
                                displayID = did
                            }
                        }
                    } else if prop.label == "isPreview", let preview = prop.value as? Bool {
                        isPreview = preview
                    } else if prop.label == "cacheDirectory", let url = prop.value as? URL {
                        // Security-scoped URL granted by WallpaperAgent for BMP snapshot writes.
                        SakuraExtensionState.shared.cacheDirectoryURL = url
                    }
                }
            }
        }

        // Extract video UUID from WallpaperCreationRequestXPC.rawValue.descriptor.configuration.
        // Private field path: request → rawValue → descriptor → configuration (UTF-8 UUID).
        // If this returns nil the extension will silently use the first library entry as a fallback.
        var choiceConfiguration: String?
        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            if let rawValue = mirror.children.first?.value {
                let rawMirror = Mirror(reflecting: rawValue)
                for prop in rawMirror.children where prop.label == "descriptor" {
                    let descMirror = Mirror(reflecting: prop.value)
                    for descProp in descMirror.children {
                        if descProp.label == "configuration",
                           let data = descProp.value as? Data, !data.isEmpty {
                            choiceConfiguration = String(data: data, encoding: .utf8)
                        }
                    }
                }
            }
            // Fallback: scan the string description for a quoted identifier field.
            if choiceConfiguration == nil {
                let desc = String(describing: reqObj)
                if let idRange = desc.range(of: "identifier: \"") {
                    let after = desc[idRange.upperBound...]
                    if let endQuote = after.firstIndex(of: "\"") {
                        choiceConfiguration = String(after[..<endQuote])
                        extensionLog("  [Choice] Fallback extraction: \(choiceConfiguration!)")
                    }
                }
            }
        }
        // --- End Mirror extraction block ---

        extensionLog("  destination: \(destSize) @\(scaleFactor)x, isPreview: \(isPreview), id: \(wallpaperIDString ?? "nil"), choice: \(choiceConfiguration ?? "nil"), displayID: \(displayID?.description ?? "nil")")

        // Convert the numeric directDisplayID to the string key used in RotationEngine / SakuraPrefs.
        // Using the raw decimal string keeps us sandbox-safe (no CoreGraphics UUID API needed)
        // and is consistent with what SakuraPrefsWriter writes on the app side.
        let displayUUID = displayID.map { "\($0)" } ?? "unknown"

        // --- CAContext creation ---

        // Tear down any previous context for this wallpaperID before creating the new one.
        // This can happen if WallpaperAgent sends a second acquire() without an intervening
        // invalidate() — e.g. on fast display reconnects or System Settings re-opens.
        if let wid = wallpaperIDString,
           let old = SakuraExtensionState.shared.context(forWallpaperID: wid) {
            old.renderer?.stop()
            Task.detached { await RotationEngine.shared.stopRotation(displayID: displayUUID) }
            extensionLog("  Stopped previous renderer for wallpaperID \(wid)")
        }

        let contextOptions: [String: Any] = displayID.map { ["displayId": $0] } ?? [:]
        let caContextRaw: Any? = contextOptions.isEmpty
            ? CAContext.remoteContext()
            : CAContext.perform(NSSelectorFromString("remoteContextWithOptions:"), with: contextOptions)?.takeUnretainedValue()

        guard let caContext = caContextRaw as? CAContext else {
            extensionLog("  ERROR: remote CAContext creation failed")
            reply(nil, NSError(domain: "SakuraWallpaper", code: 4,
                               userInfo: [NSLocalizedDescriptionKey: "Failed to create remote CAContext"]))
            return
        }
        let contextId = caContext.contextId
        guard contextId != 0 else {
            extensionLog("  ERROR: CAContext has contextId 0")
            reply(nil, NSError(domain: "SakuraWallpaper", code: 2,
                               userInfo: [NSLocalizedDescriptionKey: "CAContext contextId is 0"]))
            return
        }
        guard let replyObj = createRemoteContextXPC(contextId: contextId) else {
            reply(nil, NSError(domain: "SakuraWallpaper", code: 3,
                               userInfo: [NSLocalizedDescriptionKey: "Failed to create WallpaperRemoteContextXPC"]))
            return
        }

        // Root layer: sized to the display in points.
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: destSize)
        rootLayer.contentsScale = scaleFactor

        // Immediately show a cached still frame so there's no blank/gray flash while
        // the renderer pipeline warms up. This is the last BMP the cache wrote for this
        // video — if none exists, the root layer stays transparent (no worse than before).
        if let cachedImage = loadCachedSnapshotImage(forChoice: choiceConfiguration) {
            rootLayer.contents = cachedImage
            extensionLog("  Loaded cached BMP for instant display (choice: \(choiceConfiguration ?? "any"))")
        }

        caContext.layer = rootLayer
        CATransaction.flush()

        // Store context with renderer=nil. The renderer is created asynchronously below;
        // replaceRenderer() swaps it in once ready without holding the CAContext lock.
        _ = SakuraExtensionState.shared.storeContext(
            SakuraContext(caContext: caContext, rootLayer: rootLayer, renderer: nil,
                          displayID: displayID, videoID: choiceConfiguration),
            id: contextId,
            wallpaperID: wallpaperIDString
        )
        extensionLog("  Stored SakuraContext (contextId: \(contextId)) — renderer pending")

        // --- One-shot reply: WallpaperAgent is unblocked immediately. ---
        // Renderer creation (async) happens below without blocking the XPC call.
        reply(replyObj, nil)

        // --- Async renderer creation ---
        // Detached so actor isolation and MainActor don't interfere with the reply queue.
        let capturedContextId  = contextId
        let capturedRootLayer  = rootLayer
        let capturedChoice     = choiceConfiguration
        let capturedDisplayUID = displayUUID
        let capturedSize       = destSize
        let capturedScale      = scaleFactor

        Task.detached {
            // 500ms pause: let the WallpaperAgent process the reply and bind the remote context
            // before we start pushing frames. Starting too early can cause dropped frames.
            try? await Task.sleep(for: .milliseconds(500))

            // Resolve the video URL. The choice ID is either a library entry UUID or
            // a direct path. If nothing matches, fall back to the first library entry.
            let videoURL: URL?
            if let choiceID = capturedChoice {
                videoURL = findVideoURL(forChoice: choiceID)
            } else {
                videoURL = findVideoURL()
            }
            guard let videoURL else {
                extensionLog("[acquire] No video file found for choice \(capturedChoice ?? "any")")
                return
            }

            // 5s safety timeout: if renderer creation hangs (e.g. corrupt file, I/O stall),
            // we cancel the task so the extension process doesn't hold a stale context forever.
            let renderer: SakuraRenderer
            do {
                renderer = try await withThrowingTaskGroup(of: SakuraRenderer.self) { group in
                    group.addTask {
                        try await SakuraRenderer.create(
                            rootLayer: capturedRootLayer,
                            videoURL: videoURL
                        )
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(5))
                        throw CancellationError()
                    }
                    guard let result = try await group.next() else { throw CancellationError() }
                    group.cancelAll()
                    return result
                }
            } catch {
                extensionLog("[acquire] Renderer creation failed or timed out: \(error)")
                return
            }

            // Wire the variant selector so RotationEngine can hot-swap video files
            // at loop boundaries without stopping/restarting the renderer.
            let entryID = capturedChoice
            renderer.variantSelector = {
                guard let entryID else { return videoURL }
                let policy = SakuraPlaybackPolicy.compute(
                    presentationMode: SakuraExtensionState.shared.presentationMode,
                    activityState: SakuraExtensionState.shared.activityState,
                    userPaused: SakuraPrefsProvider.shared.userPaused,
                    alwaysPauseDesktop: SakuraPrefsProvider.shared.alwaysPauseDesktop,
                    pauseWhenOccluded: SakuraPrefsProvider.shared.pauseWhenOccluded,
                    desktopOccluded: SakuraPrefsProvider.shared.desktopOccluded,
                    thermalState: SakuraPowerMonitor.shared.currentState.thermalState,
                    isOnBattery: SakuraPowerMonitor.shared.currentState.isOnBattery,
                    batteryLevel: SakuraPowerMonitor.shared.currentState.batteryLevel,
                    isGameModeActive: SakuraPowerMonitor.shared.currentState.isGameModeActive,
                    displayBrightness: SakuraPowerMonitor.shared.currentState.displayBrightness
                )
                return SakuraLibrary.shared.bestVariantURL(for: entryID, policy: policy) ?? videoURL
            }

            // Start playback.
            renderer.start()
            extensionLog("[acquire] Renderer started for \(videoURL.lastPathComponent)")

            // Swap the stored context from nil-renderer to live-renderer.
            SakuraExtensionState.shared.replaceRenderer(renderer, contextId: capturedContextId)

            // Kick off rotation if the display has a rotation config in prefs.
            // For a brand-new display (no config yet), apply the newScreenPolicy:
            //   "blank"            — do nothing, leave entryID nil
            //   "inheritSyncGroup" — copy the first synced display's current entry
            let prefs = SakuraPrefsProvider.shared.current
            if let config = prefs.perDisplayConfig[capturedDisplayUID] {
                await RotationEngine.shared.startRotation(displayID: capturedDisplayUID, config: config)
            } else if prefs.newScreenPolicy == "inheritSyncGroup" {
                // Find the first other display that has an active entryID and copy it.
                await RotationEngine.shared.provisionNewDisplay(
                    displayID: capturedDisplayUID,
                    inheritFrom: prefs
                )
            }

            // Apply the current policy immediately (e.g. low battery, display dim).
            let powerState = SakuraPowerMonitor.shared.currentState
            let policy = SakuraPlaybackPolicy.compute(
                presentationMode: SakuraExtensionState.shared.presentationMode,
                activityState: SakuraExtensionState.shared.activityState,
                userPaused: SakuraPrefsProvider.shared.userPaused,
                alwaysPauseDesktop: SakuraPrefsProvider.shared.alwaysPauseDesktop,
                pauseWhenOccluded: SakuraPrefsProvider.shared.pauseWhenOccluded,
                desktopOccluded: SakuraPrefsProvider.shared.desktopOccluded,
                thermalState: powerState.thermalState,
                isOnBattery: powerState.isOnBattery,
                batteryLevel: powerState.batteryLevel,
                isGameModeActive: powerState.isGameModeActive,
                displayBrightness: powerState.displayBrightness
            )
            renderer.applyPolicy(policy)

            // Write a BMP snapshot so the next startup can show a still frame immediately.
            let pixelWidth  = Int(capturedSize.width  * capturedScale)
            let pixelHeight = Int(capturedSize.height * capturedScale)
            await writeBMPSnapshot(
                videoURL: videoURL,
                videoID: capturedChoice,
                displayPixelWidth: pixelWidth,
                displayPixelHeight: pixelHeight
            )
        }
    }

    // MARK: - update

    func update(withId id: Any?, request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        // Extract presentationMode and activityState from the WallpaperUpdateRequestXPC description.
        // Private fields: "presentationMode" and "activityState" in the printed representation.
        // If this returns nil the extension will silently receive no policy update.
        var presentationMode = SakuraExtensionState.shared.presentationMode
        var activityState   = SakuraExtensionState.shared.activityState
        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            if let inner = mirror.children.first?.value {
                let desc = String(describing: inner)
                if let range = desc.range(of: "presentationMode: ") {
                    let after = desc[range.upperBound...]
                    presentationMode = String(after.prefix(while: { $0 != "," && $0 != ")" }))
                }
                if let range = desc.range(of: "activityState: ") {
                    let after = desc[range.upperBound...]
                    activityState = String(after.prefix(while: { $0 != "," && $0 != ")" }))
                }
            }
        }
        SakuraExtensionState.shared.presentationMode = presentationMode
        SakuraExtensionState.shared.activityState    = activityState
        extensionLog("update — presentationMode: \(presentationMode), activityState: \(activityState)")

        // Compute the new policy for the specific renderer this update targets.
        // Using forEachRenderer here matches the behaviour for global events (thermal, battery).
        // Per-display update: we target only the renderer for this wallpaperID's display.
        var targetRenderer: SakuraRenderer?
        if let idObj = id as? NSObject {
            let idStr = String(describing: Mirror(reflecting: idObj).children.first?.value ?? "")
            if let range = idStr.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}",
                                       options: .regularExpression) {
                let wid = String(idStr[range])
                targetRenderer = SakuraExtensionState.shared.context(forWallpaperID: wid)?.renderer
            }
        }

        let powerState = SakuraPowerMonitor.shared.currentState
        let policy = SakuraPlaybackPolicy.compute(
            presentationMode: presentationMode,
            activityState: activityState,
            userPaused: SakuraPrefsProvider.shared.userPaused,
            alwaysPauseDesktop: SakuraPrefsProvider.shared.alwaysPauseDesktop,
            pauseWhenOccluded: SakuraPrefsProvider.shared.pauseWhenOccluded,
            desktopOccluded: SakuraPrefsProvider.shared.desktopOccluded,
            thermalState: powerState.thermalState,
            isOnBattery: powerState.isOnBattery,
            batteryLevel: powerState.batteryLevel,
            isGameModeActive: powerState.isGameModeActive,
            displayBrightness: powerState.displayBrightness
        )

        if let renderer = targetRenderer {
            renderer.applyPolicy(policy)
            extensionLog("update — applied policy \(policy) to targeted renderer")
        } else {
            // Fallback: no specific renderer found (rare), update all.
            SakuraExtensionState.shared.forEachRenderer { $0.applyPolicy(policy) }
            extensionLog("update — no targeted renderer, applied policy \(policy) to all")
        }

        reply(nil)
    }

    // MARK: - invalidate

    func invalidate(withId id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        var wallpaperIDString: String?
        if let idObj = id as? NSObject {
            let idStr = String(describing: Mirror(reflecting: idObj).children.first?.value ?? "")
            // Private field: UUID string inside WallpaperIDXPC.
            // If this returns nil we cannot remove the context and it will leak until removeAllContexts.
            if let range = idStr.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}",
                                       options: .regularExpression) {
                wallpaperIDString = String(idStr[range])
            }
        }

        if let wid = wallpaperIDString {
            // Look up the display UUID before removing the context so we can tell RotationEngine.
            if let ctx = SakuraExtensionState.shared.context(forWallpaperID: wid) {
                let displayUID = ctx.displayID.map { "\($0)" } ?? "unknown"
                ctx.renderer?.stop()
                Task.detached { await RotationEngine.shared.stopRotation(displayID: displayUID) }
                extensionLog("invalidate — stopped renderer + rotation for displayUID \(displayUID.suffix(8))")
            }
            _ = SakuraExtensionState.shared.removeContext(wallpaperID: wid)
            extensionLog("invalidate — removed context for wallpaperID: \(wid)")
        } else {
            extensionLog("invalidate — no wallpaperID extracted, context may leak until next removeAllContexts")
        }
        reply(nil)
    }

    // MARK: - snapshot

    func snapshot(withId _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        // SakuraBMPCache/SakuraSnapshotCreation produce the WallpaperSnapshotXPC.
        // The snapshot is used by System Settings to render the wallpaper thumbnail.
        Task.detached {
            let snapshotXPC = await createSnapshotViaRuntime()
            reply(snapshotXPC, nil)
        }
    }

    // MARK: - provideSettingsViewModels

    func provideSettingsViewModels(withContentTypes _: Any?,
                                   reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        // Minimal settings UI: file picker + rotation interval.
        // Phase 7 will add full SwiftUI controls here when the settings panel is built.
        extensionLog("provideSettingsViewModels(stub)")
        reply(nil, nil)
    }

    // MARK: - selectedChoicesDidChange

    func selectedChoicesDidChange(for id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        // `id` here is the wallpaper context ID (same type as acquire's `id` parameter).
        // The user just changed which video is selected in System Settings for this context.
        // We look up the display for this context, then re-read the current entryID from
        // prefs (which the app writes before sending selectedChoicesDidChange) and hand
        // it to RotationEngine to reset the playlist position.
        var wallpaperIDString: String?
        if let idObj = id as? NSObject {
            let idStr = String(describing: Mirror(reflecting: idObj).children.first?.value ?? "")
            if let range = idStr.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}",
                                       options: .regularExpression) {
                wallpaperIDString = String(idStr[range])
            }
        }

        if let wid = wallpaperIDString,
           let ctx = SakuraExtensionState.shared.context(forWallpaperID: wid),
           let displayID = ctx.displayID {
            let displayUID = "\(displayID)"
            // Re-read the just-updated prefs to find the new entryID for this display.
            let prefs = SakuraPrefsProvider.shared.current
            if let entryID = prefs.perDisplayConfig[displayUID]?.entryID {
                Task.detached {
                    await RotationEngine.shared.setExplicitMedia(displayID: displayUID, entryID: entryID)
                }
                extensionLog("selectedChoicesDidChange — display \(displayUID.suffix(8)): → \(entryID.suffix(8))")
            } else {
                extensionLog("selectedChoicesDidChange — no entryID in prefs for display \(displayUID.suffix(8))")
            }
        } else {
            extensionLog("selectedChoicesDidChange(no context) — id: \(String(describing: id))")
        }
        reply(nil)
    }

    // MARK: - Stubs (choices, downloads, migration, shuffle, debug)

    func addChoiceRequest(withChoiceRequest _: Any?, onBehalfOfProcess _: Any?,
                          reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extensionLog("addChoiceRequest(stub)")
        reply(nil, nil)
    }

    func removeChoiceRequest(withChoiceRequest _: Any?,
                             reply: @escaping @Sendable ((any Error)?) -> Void) {
        extensionLog("removeChoiceRequest(stub)")
        reply(nil)
    }

    func invokeContextMenuAction(withMenuItemID _: Any?, groupItemID _: Any?,
                                 reply: @escaping @Sendable ((any Error)?) -> Void) {
        extensionLog("invokeContextMenuAction(stub)")
        reply(nil)
    }

    func isChoiceDownloaded(with _: Any?,
                            reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        reply(true, nil)
    }

    func download(withChoiceID _: Any?,
                  reply: @escaping ((any Error)?) -> Void) -> Any? {
        extensionLog("download(stub)")
        reply(nil)
        return nil
    }

    func pauseDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func cancelDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func resumeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func removeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func migrateSelectedChoice(for _: Any?,
                               reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extensionLog("migrateSelectedChoice(stub)")
        reply(nil, nil)
    }

    func migrate(from _: Any?, to _: Any?,
                 reply: @escaping @Sendable ((any Error)?) -> Void) {
        extensionLog("migrate(stub)")
        reply(nil)
    }

    func skipShuffledContent(withId _: Any?,
                             reply: @escaping @Sendable ((any Error)?) -> Void) {
        extensionLog("skipShuffledContent(stub)")
        reply(nil)
    }

    func canSkipShuffledContent(withId _: Any?,
                                reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        reply(false, nil)
    }

    func handleDebugRequest(for _: Any?,
                            reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extensionLog("handleDebugRequest(stub)")
        reply(nil, nil)
    }

    func handleNotification(withNamed name: Any?,
                            reply: @escaping @Sendable ((any Error)?) -> Void) {
        extensionLog("handleNotification(stub) — \(String(describing: name))")
        reply(nil)
    }
}
