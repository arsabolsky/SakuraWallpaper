// SakuraRenderer.swift — gapless video renderer for the wallpaper extension.
// Adapted from PhospheneExtension/VideoRenderer.swift.
// Changes: VideoRenderer → SakuraRenderer, PlaybackPolicy → SakuraPlaybackPolicy,
//          layer name "phosphene.stillFrame" → "sakura.stillFrame", added more inline comments.
//
// Why AVSampleBufferDisplayLayer instead of AVPlayerLayer?
// AVPlayerLayer requires a real window and doesn't work in remote CAContexts —
// DisplaySize stays 0x0 and nothing renders. We feed CMSampleBuffers manually,
// matching exactly what Apple's built-in wallpaper engine does.
//
// Gapless looping design:
// Two AVAssetReader instances run in parallel (currentReader + nextReader).
// When currentReader exhausts, we swap readers WITHOUT flushing the display layer —
// the buffered frames keep playing while the swap happens. PTS/DTS of new samples
// from nextReader are offset by lastEnqueuedEnd to continue the monotonic timeline.
// This eliminates the visual gap that would appear with a flush-and-restart approach.

import AVFoundation
import CoreMedia

final class SakuraRenderer: @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase
    private let renderer: AVSampleBufferVideoRenderer
    // stillFrameLayer: displayed over the video during pause/ramp-down
    // so the last visible frame remains frozen instead of going black.
    private let stillFrameLayer: CALayer

    private var asset: AVURLAsset
    private var videoTrack: AVAssetTrack
    // All renderer mutations go through this queue so we never mutate the pipeline
    // from two threads simultaneously. requestMediaDataWhenReady callbacks fire here too.
    private let queue = DispatchQueue(label: "sakura.video-renderer", qos: .userInitiated)
    private var isRunning = true
    private(set) var isPaused = false
    private var currentPolicy: SakuraPlaybackPolicy = .full
    private var rampTimer: (any DispatchSourceTimer)?
    private var deepPauseTimer: (any DispatchSourceTimer)?

    // Two readers: currentReader feeds frames to the display layer;
    // nextReader is pre-built on the renderer queue while currentReader is still playing.
    // Swapping them at loop boundary is what makes looping gapless.
    private var currentReader: AVAssetReader?
    private var currentOutput: AVAssetReaderTrackOutput?
    private var nextReader: AVAssetReader?
    private var nextOutput: AVAssetReaderTrackOutput?

    // Gapless looping state.
    // ptsOffset = lastEnqueuedEnd at each loop boundary — keeps DTS and PTS
    // monotonically increasing so the display layer never has to flush.
    // B-frame note: lastEnqueuedEnd is max(end of all enqueued samples), not
    // the end of the last-enqueued sample, because B-frames arrive out of order.
    private var ptsOffset: CMTime = .zero
    private var lastEnqueuedEnd: CMTime = .zero

    /// Called at each loop boundary to select the video URL for the next iteration.
    /// Used by RotationEngine (Phase 4) to implement per-display rotation without
    /// interrupting the current loop's playback.
    var variantSelector: (() -> URL)?

    // MARK: - Factory

    /// Async factory: loads the video track before constructing the renderer
    /// so the synchronous init receives a fully loaded AVAssetTrack.
    static func create(
        rootLayer: CALayer,
        videoURL: URL
    ) async throws -> SakuraRenderer {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "No video track in \(videoURL.lastPathComponent)"
            ])
        }
        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = rootLayer.bounds
        displayLayer.contentsScale = rootLayer.contentsScale
        rootLayer.addSublayer(displayLayer)

        return SakuraRenderer(
            rootLayer: rootLayer,
            displayLayer: displayLayer,
            asset: asset,
            videoTrack: track
        )
    }

    private init(
        rootLayer: CALayer,
        displayLayer: AVSampleBufferDisplayLayer,
        asset: AVURLAsset,
        videoTrack: AVAssetTrack
    ) {
        self.displayLayer = displayLayer
        self.renderer = displayLayer.sampleBufferRenderer
        self.asset = asset
        self.videoTrack = videoTrack

        // Still-frame overlay: frozen snapshot shown during pause/ramp-down.
        // Named "sakura.stillFrame" so stale copies from a previous renderer
        // (e.g. from error recovery) can be found and removed by name.
        self.stillFrameLayer = CALayer()
        stillFrameLayer.frame = rootLayer.bounds
        stillFrameLayer.contentsGravity = .resizeAspectFill
        stillFrameLayer.contentsScale = rootLayer.contentsScale
        stillFrameLayer.opacity = 0
        stillFrameLayer.name = "sakura.stillFrame"
        // Remove any stale still frame layer from a previous renderer on this root layer.
        rootLayer.sublayers?.filter { $0.name == "sakura.stillFrame" }.forEach { $0.removeFromSuperlayer() }
        rootLayer.addSublayer(stillFrameLayer)

        // Create a CMTimebase driven by the host clock. Rate starts at 0 so
        // the timeline doesn't advance during the async gap between init and start(),
        // which would cause the first batch of frames to arrive "late" and be dropped.
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb
        )
        self.timebase = tb!
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0.0)
        displayLayer.controlTimebase = timebase
    }

    // MARK: - Lifecycle

    /// Start playback. Synchronously enqueues the first frame for immediate display
    /// (prevents the display layer from staying black for a frame), then starts
    /// the continuous feed loop and advances the timebase.
    func start() {
        guard let reader = try? AVAssetReader(asset: asset) else { return }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        // Reset the timeline before the first enqueue so the display layer
        // considers the frame on-time, not in the past.
        CMTimebaseSetTime(timebase, time: .zero)

        if let firstSample = output.copyNextSampleBuffer() {
            renderer.enqueue(firstSample)
        }

        currentReader = reader
        currentOutput = output
        ptsOffset = .zero
        lastEnqueuedEnd = .zero

        // Begin advancing time — video starts playing.
        CMTimebaseSetRate(timebase, rate: 1.0)

        // Pre-build the next reader while current is playing so the swap at loop
        // boundary is instant and doesn't stall the renderer queue.
        prepareNextReader()
        feedFromCurrentReader()
    }

    /// Stop and tear down all resources. Dispatches synchronously to the renderer
    /// queue to guarantee no callback is mid-flight when we cancel readers.
    func stop() {
        cancelDeepPauseTimer()
        queue.sync {
            isRunning = false
            renderer.stopRequestingMediaData()
            currentReader?.cancelReading()
            nextReader?.cancelReading()
        }
        displayLayer.removeFromSuperlayer()
        stillFrameLayer.removeFromSuperlayer()
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        CMTimebaseSetRate(timebase, rate: 0.0)
        generateStillFrame()
        scheduleDeepPause()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        cancelDeepPauseTimer()
        stillFrameLayer.opacity = 0
        if currentReader == nil {
            // Woke from deep pause — asset readers were freed to save memory.
            // Recreate the pipeline before resuming the timebase.
            queue.async { [weak self] in
                guard let self, isRunning else { return }
                recreatePlayback()
                CMTimebaseSetRate(timebase, rate: 1.0)
            }
        } else {
            CMTimebaseSetRate(timebase, rate: 1.0)
        }
    }

    // MARK: - Policy

    /// Apply a playback policy with optional rate ramp animation.
    /// Animated transitions are used for lock-screen appearance/dismissal (2s ease-in-out).
    /// Non-animated transitions are used for power-state changes.
    func applyPolicy(_ policy: SakuraPlaybackPolicy, animated: Bool = false) {
        guard policy != currentPolicy else { return }
        let oldPolicy = currentPolicy
        currentPolicy = policy
        cancelRamp()

        switch policy {
        case .paused:
            if animated {
                rampDown()
            } else {
                pause()
            }
        case .full, .reduced, .minimal:
            if animated, oldPolicy == .paused {
                rampUp()
            } else {
                resume()
            }
        }
    }

    // MARK: - Ramp animation (Apple lock screen–style transition)

    // 2s ease-in-out cubic at 120Hz gives a smooth, Apple-like fade.
    // Identical to the Phosphene implementation — both mirror how Apple's
    // VideoPlayer wallpaper transitions at lock/unlock.
    private static let rampDuration: TimeInterval = 2.0
    private static let rampStepInterval: TimeInterval = 1.0 / 120.0

    /// Cubic ease-in-out: smooth acceleration then deceleration.
    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5
            ? 4.0 * t * t * t
            : 1.0 - pow(-2.0 * t + 2.0, 3) / 2.0
    }

    /// Gradually reduce timebase rate to 0, then freeze and show still frame.
    private func rampDown() {
        guard !isPaused else { return }
        let totalSteps = Int(Self.rampDuration / Self.rampStepInterval)
        var step = 0

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { timer.cancel(); return }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            let eased = Self.easeInOut(progress)
            let rate = max(1.0 - eased, 0.0)
            CMTimebaseSetRate(self.timebase, rate: rate)
            if step >= totalSteps {
                timer.cancel()
                self.rampTimer = nil
                self.isPaused = true
                self.generateStillFrame()
                self.scheduleDeepPause()
            }
        }
        rampTimer = timer
        timer.resume()
    }

    /// Gradually increase timebase rate from 0 to 1.0.
    private func rampUp() {
        guard isPaused else { return }
        isPaused = false
        cancelDeepPauseTimer()
        stillFrameLayer.opacity = 0

        if currentReader == nil {
            // Deep-paused: pipeline is empty. Skip the ramp (nothing to ease into)
            // and restart immediately at full speed.
            queue.async { [weak self] in
                guard let self, isRunning else { return }
                recreatePlayback()
                CMTimebaseSetRate(timebase, rate: 1.0)
            }
            return
        }

        let totalSteps = Int(Self.rampDuration / Self.rampStepInterval)
        var step = 0
        // Start at a tiny non-zero rate so the pipeline isn't stuck at rate=0
        // during the first ramp step.
        CMTimebaseSetRate(timebase, rate: 0.01)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { timer.cancel(); return }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            let eased = Self.easeInOut(progress)
            let rate = min(eased, 1.0)
            CMTimebaseSetRate(self.timebase, rate: rate)
            if step >= totalSteps {
                timer.cancel()
                self.rampTimer = nil
            }
        }
        rampTimer = timer
        timer.resume()
    }

    private func cancelRamp() {
        rampTimer?.cancel()
        rampTimer = nil
    }

    // MARK: - Deep Pause
    //
    // After a sustained pause (overnight lock, brightness at zero, etc.) the asset
    // reader still holds the decoded frame buffer and the underlying video decoder.
    // Tearing them down frees several MB of GPU/CPU memory and lets the system idle.
    // On resume, recreatePlayback() rebuilds the pipeline from scratch.
    //
    // 30s matches Phosphene's value and balances memory savings against the cost
    // of recreating readers on unlock.

    private static let deepPauseDelay: TimeInterval = 30

    private func scheduleDeepPause() {
        cancelDeepPauseTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.deepPauseDelay)
        timer.setEventHandler { [weak self] in self?.enterDeepPause() }
        deepPauseTimer = timer
        timer.resume()
    }

    private func cancelDeepPauseTimer() {
        deepPauseTimer?.cancel()
        deepPauseTimer = nil
    }

    private func enterDeepPause() {
        deepPauseTimer = nil
        guard isRunning, isPaused, currentReader != nil else { return }
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        nextReader = nil
        nextOutput = nil
        extensionLog("[SakuraRenderer] Deep-paused — freed asset readers")
    }

    /// Rebuild the entire playback pipeline on the renderer queue.
    /// Used by both deep-pause-wake and error recovery.
    /// Caller must set timebase rate to 1.0 after this returns.
    private func recreatePlayback() {
        renderer.stopRequestingMediaData()
        renderer.flush()
        ptsOffset = .zero
        lastEnqueuedEnd = .zero
        CMTimebaseSetTime(timebase, time: .zero)

        currentReader?.cancelReading()
        nextReader?.cancelReading()
        nextReader = nil
        nextOutput = nil

        guard let reader = try? AVAssetReader(asset: asset) else {
            extensionLog("[SakuraRenderer] Failed to create reader during recreate")
            currentReader = nil
            currentOutput = nil
            return
        }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        currentReader = reader
        currentOutput = output

        prepareNextReader()
        feedFromCurrentReader()
    }

    // MARK: - Preloaded Loop Reader

    /// Begin building the next reader asynchronously. If variantSelector provides
    /// a different URL, that URL's track must be loaded via AVAsset.loadTracks (async);
    /// we hand that off to a detached Task rather than blocking the renderer queue.
    private func prepareNextReader() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            let nextURL = variantSelector?()
            if let nextURL, nextURL != asset.url {
                // Different URL for the next loop iteration — need async track load.
                let newAsset = AVURLAsset(url: nextURL)
                Task.detached { @Sendable [weak self] in
                    guard let self else { return }
                    guard let track = try? await newAsset.loadTracks(withMediaType: .video).first else {
                        extensionLog("[SakuraRenderer] No video track in variant: \(nextURL.lastPathComponent)")
                        return
                    }
                    nonisolated(unsafe) let loadedTrack = track
                    queue.async { [weak self] in
                        guard let self, isRunning else { return }
                        installNextReader(asset: newAsset, track: loadedTrack)
                    }
                }
            } else {
                // Same file for next loop — reader is trivial to build synchronously.
                installNextReader(asset: asset, track: videoTrack)
            }
        }
    }

    /// Build a reader for the pre-loaded loop and park it in nextReader/nextOutput.
    /// Called on the renderer queue only.
    private func installNextReader(asset: AVURLAsset, track: AVAssetTrack) {
        guard let reader = try? AVAssetReader(asset: asset) else {
            extensionLog("[SakuraRenderer] Failed to create next reader")
            return
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        nextReader = reader
        nextOutput = output
    }

    /// Swap to the preloaded next reader at a loop boundary.
    /// No flush — the display layer keeps playing from its internal buffer while
    /// we swap. The PTS/DTS offset makes the new reader's timeline continuous.
    private func swapToNextReader() {
        renderer.stopRequestingMediaData()

        // ptsOffset = lastEnqueuedEnd so the next loop's samples continue the
        // monotonic timeline. Without this, the next loop would start at PTS 0
        // which is in the past and the display layer would drop all the frames.
        ptsOffset = lastEnqueuedEnd

        if let nr = nextReader, let no = nextOutput {
            if let nrAsset = nr.asset as? AVURLAsset, nrAsset.url != asset.url {
                asset = nrAsset
                videoTrack = no.track
                extensionLog("[SakuraRenderer] Variant switched: \(nrAsset.url.lastPathComponent)")
            }
            currentReader = nr
            currentOutput = no
            nextReader = nil
            nextOutput = nil
        } else {
            // Next reader wasn't ready (e.g. async track load still in flight).
            // Fall back to a synchronous reader on the same asset.
            extensionLog("[SakuraRenderer] Next reader not ready, creating synchronously")
            guard let reader = try? AVAssetReader(asset: asset) else {
                extensionLog("[SakuraRenderer] Failed to create fallback reader")
                return
            }
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            currentReader = reader
            currentOutput = output
        }

        currentReader?.startReading()
        prepareNextReader()
        feedFromCurrentReader()
    }

    // MARK: - Feed Loop

    private func feedFromCurrentReader() {
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, isRunning else {
                self?.renderer.stopRequestingMediaData()
                return
            }

            // Unrecoverable decoder failure — full reset.
            // Dispatch async: requestMediaDataWhenReady is not reentrant.
            if renderer.status == .failed {
                extensionLog("[SakuraRenderer] Decoder failed: \(renderer.error?.localizedDescription ?? "unknown"), recovering")
                renderer.stopRequestingMediaData()
                queue.async { [weak self] in self?.recoverFromError() }
                return
            }

            // Decoder hit a discontinuity (seek, gap, etc.) — flush to resume.
            if renderer.requiresFlushToResumeDecoding {
                renderer.flush()
            }

            while renderer.isReadyForMoreMediaData {
                if let sample = currentOutput?.copyNextSampleBuffer() {
                    // PTS/DTS offset: shifts this sample into the monotonic timeline.
                    // The display layer never flushes between loops — this is the key
                    // to gapless looping. First loop has ptsOffset = .zero, so no copy.
                    let adjusted = offsetTimingForLoop(sample)

                    // Track the highest sample end time (max, not last).
                    // B-frames arrive out of DTS order; taking max ensures lastEnqueuedEnd
                    // is always the true end of the last presented frame.
                    // Skip samples with invalid PTS (container padding) to prevent NaN
                    // from poisoning the offset on the next loop boundary.
                    let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
                    let dur = CMSampleBufferGetDuration(adjusted)
                    if pts.isValid {
                        let end = dur.isValid && dur > .zero
                            ? CMTimeAdd(pts, dur)
                            : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
                        if end > lastEnqueuedEnd {
                            lastEnqueuedEnd = end
                        }
                    }
                    renderer.enqueue(adjusted)
                } else {
                    // currentReader exhausted — loop boundary.
                    // Dispatch async: requestMediaDataWhenReady is not reentrant.
                    renderer.stopRequestingMediaData()
                    queue.async { [weak self] in self?.swapToNextReader() }
                    return
                }
            }
        }
    }

    /// Offset DTS and PTS of a CMSampleBuffer for gapless looping.
    /// For the first loop (ptsOffset == .zero) returns the original buffer unchanged —
    /// no copy, no extra allocation. For subsequent loops, creates a lightweight timing
    /// copy that shares the underlying frame data buffer.
    private func offsetTimingForLoop(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard ptsOffset > .zero else { return sample }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        let dur = CMSampleBufferGetDuration(sample)

        var timingInfo = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: pts.isValid ? CMTimeAdd(pts, ptsOffset) : pts,
            // DTS must also be offset — some decoders use DTS for decode scheduling.
            // .invalid means DTS == PTS for this sample; leave it invalid so the
            // decoder doesn't get a spurious non-monotonic decode timestamp.
            decodeTimeStamp: dts.isValid ? CMTimeAdd(dts, ptsOffset) : .invalid
        )

        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjusted
        )
        return adjusted ?? sample
    }

    private func recoverFromError() {
        recreatePlayback()
        CMTimebaseSetRate(timebase, rate: isPaused ? 0.0 : 1.0)
    }

    // MARK: - Still Frame

    /// Capture a still frame from the current asset at the timebase's current position.
    /// Used to keep the last visible frame visible while the video is paused, rather
    /// than showing a blank or blurred compositing layer.
    private func generateStillFrame() {
        let captureTime = CMTimebaseGetTime(timebase)
        let currentAsset = asset

        Task.detached(priority: .userInitiated) { [weak self] in
            let generator = AVAssetImageGenerator(asset: currentAsset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.appliesPreferredTrackTransform = true

            guard let (cgImage, _) = try? await generator.image(at: captureTime) else {
                extensionLog("[SakuraRenderer] Failed to generate still frame at \(captureTime.seconds)s")
                return
            }

            await MainActor.run { [weak self] in
                guard let self, self.isPaused else { return }
                self.stillFrameLayer.contents = cgImage
                self.stillFrameLayer.opacity = 1
            }
        }
    }
}
