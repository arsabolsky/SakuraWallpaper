// SakuraXPCHandler.swift — XPC handler implementing WallpaperExtensionXPCProtocol.
//
// Phase 1: All six lifecycle methods are stubbed — they log their name and call
// reply() immediately so the extension compiles and registers with the system.
//
// The Mirror-reflection extraction block in acquire() is copied from
// PhospheneExtension/WallpaperXPCHandler.swift because it parses private
// WallpaperExtensionKit types; the field names are OS-level and identical for
// any macOS 26 wallpaper extension.
//
// Full implementation lands in Phase 5 once SakuraRenderer (Phase 2),
// SakuraLibrary (Phase 3), and RotationEngine (Phase 4) are in place.

import AppKit
import AVFoundation
import CoreMedia
import os
import QuartzCore

final class SakuraXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    /// Proxy to call methods on WallpaperAgent (ping, invalidateSnapshots, etc.).
    var agentProxy: (any WallpaperExtensionProxyXPCProtocol)?

    // MARK: - Lifecycle

    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extensionLog("=== ACQUIRE (stub) ===")

        // --- Mirror extraction block — copied from PhospheneExtension/WallpaperXPCHandler.swift ---
        // WallpaperCreationRequestXPC fields are not in the public SDK; we read them via
        // Mirror reflection. Each access is guarded: if Apple renames a field, the guard
        // returns nil / the fallback fires and we log a warning rather than crashing.

        // Extract WallpaperID UUID (used for cleanup in invalidate).
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

        // Extract destination size from WallpaperCreationRequestXPC.
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
                        SakuraExtensionState.shared.cacheDirectoryURL = url
                    }
                }
            }
        }

        // Extract choice configuration (video UUID) from the request descriptor.
        // Private field path: WallpaperCreationRequestXPC.rawValue.descriptor.configuration
        // If this returns nil the extension will silently receive no render context.
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
                            // Private field: "configuration" is the video UUID as UTF-8 data.
                            choiceConfiguration = String(data: data, encoding: .utf8)
                        }
                    }
                }
            }
            // Fallback: parse the string description if Mirror traversal found nothing.
            if choiceConfiguration == nil {
                let desc = String(describing: reqObj)
                if let idRange = desc.range(of: "identifier: \"") {
                    let after = desc[idRange.upperBound...]
                    if let endQuote = after.firstIndex(of: "\"") {
                        choiceConfiguration = String(after[..<endQuote])
                        extensionLog("  [Choice] Fallback extraction from description: \(choiceConfiguration!)")
                    }
                }
            }
        }
        // --- End Mirror extraction block ---

        extensionLog("  destination: \(destSize) @\(scaleFactor)x, isPreview: \(isPreview), id: \(wallpaperIDString ?? "nil"), choice: \(choiceConfiguration ?? "nil"), displayID: \(displayID?.description ?? "nil")")

        // Phase 1 stub: return a solid-colour layer so the system wallpaper picker
        // shows *something* while the real renderer is implemented in Phase 2.
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

        // Placeholder root layer — solid pink until Phase 2 wires in the real renderer.
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: destSize)
        rootLayer.contentsScale = scaleFactor
        rootLayer.backgroundColor = CGColor(red: 1, green: 0.4, blue: 0.6, alpha: 1) // sakura pink
        caContext.layer = rootLayer
        CATransaction.flush()

        _ = SakuraExtensionState.shared.storeContext(
            SakuraContext(caContext: caContext, rootLayer: rootLayer, renderer: nil,
                          displayID: displayID, videoID: choiceConfiguration),
            id: contextId,
            wallpaperID: wallpaperIDString
        )
        extensionLog("  Stored SakuraContext (contextId: \(contextId)) — Phase 1 placeholder layer")
        reply(replyObj, nil)
    }

    func update(withId _: Any?, request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        // Extract presentationMode and activityState from WallpaperUpdateRequestXPC.
        // Private field: Mirror-traversed from the request's inner value.
        // If this returns nil the extension will silently receive no policy update.
        var presentationMode = "active"
        var activityState   = "active"
        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            if let inner = mirror.children.first?.value {
                let desc = String(describing: inner)
                // Private fields: "presentationMode" and "activityState" in the description string.
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
        extensionLog("update(stub) — presentationMode: \(presentationMode), activityState: \(activityState)")
        reply(nil)
    }

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
            _ = SakuraExtensionState.shared.removeContext(wallpaperID: wid)
            extensionLog("invalidate — removed context for wallpaperID: \(wid)")
        } else {
            extensionLog("invalidate(stub) — no wallpaperID extracted, context may leak until next removeAllContexts")
        }
        reply(nil)
    }

    func snapshot(withId id: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        // Phase 1 stub — SakuraSnapshotCreation (Phase 5) will provide the real BMP.
        extensionLog("snapshot(stub) — returning nil, Phase 5 will implement BMP generation")
        reply(nil, nil)
    }

    func provideSettingsViewModels(withContentTypes _: Any?,
                                   reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        // Phase 5 stub — minimal settings UI populated in Phase 5.
        extensionLog("provideSettingsViewModels(stub)")
        reply(nil, nil)
    }

    func selectedChoicesDidChange(for id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        // Phase 5 stub — will call RotationEngine.setExplicitMedia when wired up.
        extensionLog("selectedChoicesDidChange(stub) — id: \(String(describing: id))")
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
                  reply: @escaping @Sendable ((any Error)?) -> Void) -> Any? {
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
