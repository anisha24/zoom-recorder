import AVFoundation
import CoreImage
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case zoomWindowNotFound
    case zoomNotRunning
    case writerFailed(Error?)
    case noVideoCaptured

    var errorDescription: String? {
        switch self {
        case .zoomWindowNotFound:
            return "No Zoom meeting window found. Join a meeting first (the window must be on screen)."
        case .zoomNotRunning:
            return "Zoom isn't running."
        case .writerFailed(let error):
            return "Could not write the recording: \(error?.localizedDescription ?? "unknown error")"
        case .noVideoCaptured:
            return "No video frames were captured."
        }
    }
}

/// Meeting-recorder style presets: modest resolution, low frame rate and HEVC keep files to
/// a few hundred MB per hour while slides and shared-screen text stay readable.
enum RecordingQuality: String, CaseIterable, Identifiable {
    case standard, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard: 720p, about 250 MB per hour per Zoom screen"
        case .high: return "High: 1080p, about 550 MB per hour per Zoom screen"
        }
    }

    /// Size limit for each Zoom window.
    var maxPixelSize: CGSize {
        switch self {
        case .standard: return CGSize(width: 1280, height: 800)
        case .high: return CGSize(width: 1920, height: 1200)
        }
    }

    var framesPerSecond: Int32 { 15 }

    /// HEVC bitrate per output pixel per second.
    var bitsPerPixel: Double {
        switch self {
        case .standard: return 0.5
        case .high: return 0.45
        }
    }
}

/// Records every Zoom meeting window (Zoom's dual-monitor mode uses one per screen), composited
/// side by side into one video track, plus Zoom's audio and the microphone on two audio tracks.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let maxWindows = 4

    /// Called when the audio stream ends on its own (e.g. Zoom quit).
    var onUnexpectedStop: ((Error) -> Void)?
    var onWindowCountChanged: ((Int) -> Void)?

    private let isMicMuted: () -> Bool
    private let writerQueue = DispatchQueue(label: "ZoomRecorder.writer", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "ZoomRecorder.frames", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private var quality: RecordingQuality = .standard
    private var audioStream: SCStream?
    private var rescanTask: Task<Void, Never>?

    private let sourcesLock = NSLock()
    private var sources: [CGWindowID: WindowSource] = [:]

    // Writer state: only touched on writerQueue once recording has started.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStart: CMTime?
    private var canvasSize = CGSize.zero
    private var renderTimer: DispatchSourceTimer?
    private var lastSignature: [Int] = []
    private var lastFrameTime = CMTime.negativeInfinity
    private var framesWritten = 0

    init(isMicMuted: @escaping () -> Bool) {
        self.isMicMuted = isMicMuted
    }

    // MARK: - Window discovery

    static func meetingWindows(in content: SCShareableContent) -> [SCWindow] {
        let zoomWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == MuteMonitor.zoomBundleID
                && $0.windowLayer == 0 && $0.isOnScreen
                && $0.frame.width >= 320 && $0.frame.height >= 240
        }
        let title = { (w: SCWindow) in (w.title ?? "").lowercased() }
        let titled = zoomWindows.filter { title($0).contains("meeting") || title($0).contains("webinar") }
        guard !titled.isEmpty else { return [] }

        // Zoom's second dual-monitor window isn't reliably titled "Zoom Meeting", so also take
        // large Zoom windows that sit apart from the titled ones (i.e. on another screen).
        let notMeeting = ["workplace", "settings", "chat", "participants", "contacts", "home"]
        let extra = zoomWindows.filter { w in
            !titled.contains { $0.windowID == w.windowID }
                && w.frame.width >= 640 && w.frame.height >= 360
                && !notMeeting.contains { title(w).contains($0) }
                && !titled.contains { $0.frame.intersects(w.frame) }
        }
        return Array((titled + extra).sorted { $0.frame.minX < $1.frame.minX }.prefix(maxWindows))
    }

    // MARK: - Lifecycle

    func start(outputURL: URL, quality: RecordingQuality) async throws {
        self.quality = quality
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = Self.meetingWindows(in: content)
        guard !windows.isEmpty else { throw RecorderError.zoomWindowNotFound }
        guard let zoomApp = content.applications.first(where: { $0.bundleIdentifier == MuteMonitor.zoomBundleID }),
              let display = content.displays.first else { throw RecorderError.zoomNotRunning }

        let pixelSizes = windows.map { window -> CGSize in
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            return CGSize(width: filter.contentRect.width * scale, height: filter.contentRect.height * scale)
        }
        let canvas = Self.canvasSize(forPixelSizes: pixelSizes, quality: quality)
        let writer = try makeWriter(url: outputURL, canvas: canvas)

        // Audio comes from a separate app-filtered stream so it survives meeting windows
        // opening and closing; its video output is a throwaway 2x2 frame once a second.
        let audioConfig = SCStreamConfiguration()
        audioConfig.width = 2
        audioConfig.height = 2
        audioConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        audioConfig.capturesAudio = true
        audioConfig.excludesCurrentProcessAudio = true
        audioConfig.sampleRate = 48_000
        audioConfig.channelCount = 2
        audioConfig.captureMicrophone = true
        let audioFilter = SCContentFilter(display: display, including: [zoomApp], exceptingWindows: [])
        let audioStream = SCStream(filter: audioFilter, configuration: audioConfig, delegate: self)
        try audioStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
        try audioStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
        try audioStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: writerQueue)

        do {
            try await audioStream.startCapture()
            self.audioStream = audioStream
            for window in windows {
                try? await addSource(window)
            }
            guard sourceCount > 0 else { throw RecorderError.zoomWindowNotFound }
        } catch {
            try? await audioStream.stopCapture()
            self.audioStream = nil
            await stopSources()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        writerQueue.sync {
            let now = Self.hostTime()
            sessionStart = now
            writer.startSession(atSourceTime: now)
            startRenderTimer()
        }
        startRescanning()
    }

    /// Stops capture and finalizes the file. Returns the URL of the raw multi-track recording.
    func stop() async throws -> URL {
        rescanTask?.cancel()
        rescanTask = nil
        await stopSources()
        if let audioStream {
            try? await audioStream.stopCapture()
        }
        audioStream = nil

        let (writer, inputs, frames): (AVAssetWriter?, [AVAssetWriterInput], Int) = writerQueue.sync {
            renderTimer?.cancel()
            renderTimer = nil
            let result = (self.writer, [videoInput, systemAudioInput, micInput].compactMap { $0 }, framesWritten)
            self.writer = nil
            videoInput = nil; adaptor = nil; systemAudioInput = nil; micInput = nil
            return result
        }
        guard let writer else { throw RecorderError.writerFailed(nil) }
        guard frames > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
            throw RecorderError.noVideoCaptured
        }
        inputs.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw RecorderError.writerFailed(writer.error) }
        return writer.outputURL
    }

    private func makeWriter(url: URL, canvas: CGSize) throws -> AVAssetWriter {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Fragmented writes keep the file recoverable if the app dies mid-meeting.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let width = Int(canvas.width), height = Int(canvas.height)
        let bitrate = max(250_000, Int(Double(width * height) * quality.bitsPerPixel))
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: quality.framesPerSecond,
                AVVideoMaxKeyFrameIntervalDurationKey: 4,
                AVVideoAllowFrameReorderingKey: true,
            ],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        let systemAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.pcmSettings(channels: 2))
        let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.pcmSettings(channels: 1))
        for input in [video, systemAudio, mic] {
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.writerFailed(writer.error) }
            writer.add(input)
        }
        guard writer.startWriting() else { throw RecorderError.writerFailed(writer.error) }

        writerQueue.sync {
            self.writer = writer
            self.videoInput = video
            self.adaptor = adaptor
            self.systemAudioInput = systemAudio
            self.micInput = mic
            self.canvasSize = canvas
            self.sessionStart = nil
            self.framesWritten = 0
            self.lastSignature = []
            self.lastFrameTime = .negativeInfinity
        }
        return writer
    }

    // MARK: - Window sources

    private var sourceCount: Int { sourcesLock.withLock { sources.count } }

    private func addSource(_ window: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let (width, height) = Self.outputSize(for: filter.contentRect.size,
                                              scale: CGFloat(filter.pointPixelScale),
                                              fitting: quality.maxPixelSize)
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: quality.framesPerSecond)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 4

        let source = WindowSource(windowID: window.windowID, originX: window.frame.minX)
        source.onStop = { [weak self] id in self?.removeSource(id) }
        let stream = SCStream(filter: filter, configuration: config, delegate: source)
        try stream.addStreamOutput(source, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
        source.stream = stream

        let count = sourcesLock.withLock {
            sources[window.windowID] = source
            return sources.count
        }
        onWindowCountChanged?(count)
    }

    private func removeSource(_ id: CGWindowID) {
        let count = sourcesLock.withLock {
            sources[id] = nil
            return sources.count
        }
        onWindowCountChanged?(count)
    }

    private func stopSources() async {
        let all = sourcesLock.withLock {
            defer { sources.removeAll() }
            return Array(sources.values)
        }
        for source in all {
            try? await source.stream?.stopCapture()
        }
    }

    /// Picks up meeting windows that appear mid-meeting (e.g. a second screen or a shared screen).
    private func startRescanning() {
        rescanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled,
                      let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                else { continue }
                let known = self.sourcesLock.withLock { Set(self.sources.keys) }
                for window in Self.meetingWindows(in: content)
                where !known.contains(window.windowID) && self.sourceCount < Self.maxWindows {
                    try? await self.addSource(window)
                }
            }
        }
    }

    // MARK: - Compositing

    private func startRenderTimer() {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        let interval = 1.0 / Double(quality.framesPerSecond)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.renderFrame() }
        timer.resume()
        renderTimer = timer
    }

    private func renderFrame() {
        guard let writer, writer.status == .writing, let adaptor, let videoInput,
              videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }

        let ordered = sourcesLock.withLock { sources.values.sorted { $0.originX < $1.originX } }
        let frames = ordered.compactMap { $0.latestFrame() }
        let signature = frames.map(\.generation)
        let now = Self.hostTime()

        // Skip identical frames, but write at least one a second so the video track keeps pace.
        if signature == lastSignature && (now - lastFrameTime).seconds < 1 { return }

        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output else { return }

        let bounds = CGRect(origin: .zero, size: canvasSize)
        var image = CIImage(color: .black).cropped(to: bounds)
        let tiles = Self.layout(sizes: frames.map { CGSize(width: CVPixelBufferGetWidth($0.buffer),
                                                           height: CVPixelBufferGetHeight($0.buffer)) },
                                in: canvasSize)
        for (frame, rect) in zip(frames, tiles) {
            let source = CIImage(cvPixelBuffer: frame.buffer)
            let scale = rect.width / max(source.extent.width, 1)
            let tile = source
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            image = tile.composited(over: image)
        }
        ciContext.render(image, to: output, bounds: bounds, colorSpace: colorSpace)

        if adaptor.append(output, withPresentationTime: now) {
            framesWritten += 1
            lastSignature = signature
            lastFrameTime = now
        }
    }

    /// Lays tiles out left to right at a common height, scaled down to fit and centered.
    static func layout(sizes: [CGSize], in canvas: CGSize, gap: CGFloat = 8) -> [CGRect] {
        guard !sizes.isEmpty else { return [] }
        let widths = sizes.map { $0.width / max($0.height, 1) * canvas.height }
        let total = widths.reduce(0, +) + gap * CGFloat(sizes.count - 1)
        let scale = min(1, canvas.width / total)
        let height = canvas.height * scale
        var x = (canvas.width - total * scale) / 2
        let y = (canvas.height - height) / 2
        return widths.map { w in
            defer { x += (w + gap) * scale }
            return CGRect(x: x, y: y, width: w * scale, height: height).integral
        }
    }

    /// Canvas big enough for the windows present at start, each limited to the quality's size.
    static func canvasSize(forPixelSizes windowSizes: [CGSize], quality: RecordingQuality) -> CGSize {
        let limit = quality.maxPixelSize
        let tiles = windowSizes.map { size -> CGSize in
            let (w, h) = outputSize(for: size, scale: 1, fitting: limit)
            return CGSize(width: w, height: h)
        }
        let height = tiles.map(\.height).max() ?? limit.height
        let gap: CGFloat = 8
        let width = tiles.map { $0.width / max($0.height, 1) * height }.reduce(0, +)
            + gap * CGFloat(max(tiles.count - 1, 0))
        let maxWidth = limit.width * CGFloat(min(tiles.count, 2))
        let fit = min(1, maxWidth / max(width, 1))
        let even = { (v: CGFloat) in CGFloat(max(2, Int(v) & ~1)) }
        return CGSize(width: even(width * fit), height: even(height * fit))
    }

    // MARK: - SCStreamOutput (audio stream)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer, writer.status == .writing else { return }
        switch type {
        case .audio:
            append(audio: sampleBuffer, to: systemAudioInput)
        case .microphone:
            if isMicMuted() {
                Self.silence(sampleBuffer)
            }
            append(audio: sampleBuffer, to: micInput)
        case .screen:
            break
        @unknown default:
            break
        }
    }

    private func append(audio sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, let start = sessionStart,
              sampleBuffer.presentationTimeStamp >= start,
              input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    // MARK: - SCStreamDelegate (audio stream)

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        writerQueue.async { [weak self] in self?.onUnexpectedStop?(error) }
    }

    // MARK: - Helpers

    static func hostTime() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else { return false }
        return CMSampleBufferGetImageBuffer(sampleBuffer) != nil
    }

    /// Zeroes the PCM samples in place so the mic track keeps its timing while muted.
    private static func silence(_ sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
    }

    private static func pcmSettings(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    static func outputSize(for points: CGSize, scale: CGFloat, fitting limit: CGSize) -> (Int, Int) {
        var w = points.width * scale
        var h = points.height * scale
        let fit = min(1, limit.width / max(w, 1), limit.height / max(h, 1))
        w *= fit
        h *= fit
        let even = { (v: CGFloat) in max(2, Int(v) & ~1) }
        return (even(w), even(h))
    }
}

/// One captured Zoom window; keeps only its most recent frame for the compositor.
private final class WindowSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame {
        let buffer: CVPixelBuffer
        let generation: Int
    }

    let windowID: CGWindowID
    let originX: CGFloat
    var stream: SCStream?
    var onStop: ((CGWindowID) -> Void)?

    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var generation = 0

    init(windowID: CGWindowID, originX: CGFloat) {
        self.windowID = windowID
        self.originX = originX
    }

    func latestFrame() -> Frame? {
        lock.withLock { latest.map { Frame(buffer: $0, generation: generation) } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Recorder.isCompleteFrame(sampleBuffer),
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.withLock {
            latest = buffer
            generation += 1
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(windowID)
    }
}
