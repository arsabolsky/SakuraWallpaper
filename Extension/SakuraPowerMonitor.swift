// SakuraPowerMonitor.swift — monitors thermal, battery, and display brightness state.
// Adapted from PhospheneExtension/PowerMonitor.swift.
// Changes: class renamed SakuraPowerMonitor, scheduler identifier uses com.sakura.wallpaper.
//
// Consumers observe state changes via `stateChanges()` — an AsyncStream that yields
// immediately on subscription and again whenever any component of power state changes.

import Foundation
import IOKit.ps
import os

final class SakuraPowerMonitor: Sendable {
    static let shared = SakuraPowerMonitor()

    private let state = OSAllocatedUnfairLock(initialState: PowerState())
    private let continuations = OSAllocatedUnfairLock(
        initialState: [UUID: AsyncStream<PowerState>.Continuation]()
    )
    // NSBackgroundActivityScheduler isn't Sendable; nonisolated(unsafe) because it is
    // only written once during startMonitoring() and never mutated after that.
    nonisolated(unsafe) private var _batteryScheduler: NSBackgroundActivityScheduler?

    // MARK: - PowerState

    struct PowerState: Sendable, Equatable {
        var thermalState: ProcessInfo.ThermalState = .nominal
        var isOnBattery = false
        var batteryLevel: Int = 100
        /// Game Mode detection via Darwin notification is not available to sandboxed extensions;
        /// this field defaults to false and is reserved for future use.
        var isGameModeActive: Bool = false
        /// Backlight brightness of the built-in display (0.0–1.0).
        /// Defaults to 1.0 when the value can't be read (external displays, headless, etc.)
        /// so the policy never incorrectly demotes to paused on those systems.
        var displayBrightness: Float = 1.0

        /// Convenience: whether any condition independently requires pausing.
        var shouldPause: Bool {
            if thermalState == .critical || thermalState == .serious { return true }
            if isOnBattery, batteryLevel < 20 { return true }
            if displayBrightness < Self.brightnessPauseThreshold { return true }
            return false
        }

        /// Below this brightness the screen is effectively invisible to the user
        /// even though screensDidSleepNotification hasn't fired. We treat this
        /// as paused so the renderer stops burning battery on a black screen.
        static let brightnessPauseThreshold: Float = 0.05
    }

    private init() {}

    /// Current power state snapshot.
    var currentState: PowerState {
        state.withLock { $0 }
    }

    /// Whether power conditions require pausing playback.
    var shouldPause: Bool {
        state.withLock { $0.shouldPause }
    }

    // MARK: - AsyncStream subscriber

    /// Returns an AsyncStream that yields the current state immediately and then
    /// again whenever any component of power state changes.
    func stateChanges() -> AsyncStream<PowerState> {
        let (stream, continuation) = AsyncStream.makeStream(of: PowerState.self)
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { $0[id] = nil }
        }
        // Yield immediately so the consumer has a baseline state before any changes.
        continuation.yield(currentState)
        return stream
    }

    // MARK: - Monitoring lifecycle

    /// Start monitoring power state. Call once at extension startup after dlopen.
    func startMonitoring() {
        state.withLock { $0.thermalState = ProcessInfo.processInfo.thermalState }
        updateBatteryState()
        updateBrightnessState()

        // Thermal state — event-driven; no polling needed.
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.handleThermalChange()
        }

        // Battery + brightness — OS-managed periodic check. Brightness needs polling
        // because IODisplay doesn't broadcast a notification when the slider moves,
        // and screensDidSleep doesn't fire when brightness is held at zero manually.
        let scheduler = NSBackgroundActivityScheduler(
            identifier: "com.sakura.wallpaper.powerCheck"
        )
        scheduler.interval = 30
        scheduler.tolerance = 15
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        nonisolated(unsafe) let capturedScheduler = scheduler
        scheduler.schedule { [weak self] completion in
            guard let self else { completion(.finished); return }
            if capturedScheduler.shouldDefer { completion(.deferred); return }
            updateBatteryState()
            updateBrightnessState()
            completion(.finished)
        }
        _batteryScheduler = scheduler

        extensionLog("[SakuraPowerMonitor] Started (thermal: \(ProcessInfo.processInfo.thermalState.rawValue))")
    }

    // MARK: - Private update handlers

    private func handleThermalChange() {
        let previous = state.withLock { $0 }
        state.withLock { $0.thermalState = ProcessInfo.processInfo.thermalState }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extensionLog("[SakuraPowerMonitor] Thermal → shouldPause: \(current.shouldPause)")
        yieldToSubscribers(current)
    }

    private func updateBatteryState() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        else { return }

        let isOnBattery: Bool
        if let powerSource = desc[kIOPSPowerSourceStateKey] as? String {
            isOnBattery = powerSource == kIOPSBatteryPowerValue
        } else {
            isOnBattery = false
        }
        let batteryLevel = desc[kIOPSCurrentCapacityKey] as? Int ?? 100

        let previous = state.withLock { $0 }
        state.withLock { s in
            s.isOnBattery = isOnBattery
            s.batteryLevel = batteryLevel
        }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extensionLog("[SakuraPowerMonitor] Battery → \(batteryLevel)% onBattery: \(isOnBattery), shouldPause: \(current.shouldPause)")
        yieldToSubscribers(current)
    }

    /// Read the built-in display backlight via IORegistry. Returns nil on systems
    /// without a backlight (Mac mini, Mac Studio, external-only setups) — callers
    /// default to 1.0 so the policy is never wrongly demoted on those machines.
    private func updateBrightnessState() {
        let brightness = Self.readBuiltInBrightness() ?? 1.0
        let previous = state.withLock { $0 }
        state.withLock { $0.displayBrightness = brightness }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extensionLog("[SakuraPowerMonitor] Brightness → \(brightness), shouldPause: \(current.shouldPause)")
        yieldToSubscribers(current)
    }

    private static func readBuiltInBrightness() -> Float? {
        // Private API: read the "IODisplayParameters" key from the AppleBacklightDisplay
        // IOService. This is the same IOKit path used by Phosphene and other open-source
        // macOS brightness tools. Returns nil on external-only systems.
        let matching = IOServiceMatching("AppleBacklightDisplay")
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        var brightness: Float?
        while case let service = IOIteratorNext(iter), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let propsRef = IORegistryEntryCreateCFProperty(
                service, "IODisplayParameters" as CFString, kCFAllocatorDefault, 0
            ) else { continue }
            guard let params = propsRef.takeRetainedValue() as? [String: Any],
                  let brightnessParam = params["brightness"] as? [String: Any],
                  let value = brightnessParam["value"] as? Int,
                  let min   = brightnessParam["min"]   as? Int,
                  let max   = brightnessParam["max"]   as? Int,
                  max > min
            else { continue }
            brightness = Float(value - min) / Float(max - min)
            break
        }
        return brightness
    }

    private func yieldToSubscribers(_ state: PowerState) {
        continuations.withLock { conts in
            for cont in conts.values { cont.yield(state) }
        }
    }
}
