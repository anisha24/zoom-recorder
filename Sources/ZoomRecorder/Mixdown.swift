import AVFoundation

enum MixdownError: LocalizedError {
    case noVideoTrack
    case failed(Error?)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The raw recording has no video track."
        case .failed(let error): return error?.localizedDescription ?? "Mixdown failed."
        }
    }
}

/// Turns the raw recording (video + meeting audio + mic audio) into a single MP4 with one
/// mixed AAC audio track. Video is copied without re-encoding.
enum Mixdown {
    static func run(input: URL, output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MixdownError.noVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let mix = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            mix.alwaysCopiesSampleData = false
            reader.add(mix)
            audioOutput = mix
        }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let formatHint = try await videoTrack.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 96_000,
            ])
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else { throw MixdownError.failed(reader.error) }
        guard writer.startWriting() else { throw MixdownError.failed(writer.error) }

        guard let firstVideo = videoOutput.copyNextSampleBuffer() else {
            reader.cancelReading()
            writer.cancelWriting()
            throw MixdownError.noVideoTrack
        }
        writer.startSession(atSourceTime: firstVideo.presentationTimeStamp)

        async let videoDone: Void = pump(videoOutput, into: videoInput, first: firstVideo, label: "video")
        if let audioOutput, let audioInput {
            await pump(audioOutput, into: audioInput, first: nil, label: "audio")
        }
        await videoDone

        if reader.status == .failed || writer.status == .failed {
            let error = reader.error ?? writer.error
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw MixdownError.failed(error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw MixdownError.failed(writer.error) }
    }

    /// Only touched from the pump's serial queue.
    private final class PumpState: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        var pending: CMSampleBuffer?
        var finished = false
        init(output: AVAssetReaderOutput, input: AVAssetWriterInput, pending: CMSampleBuffer?) {
            self.output = output
            self.input = input
            self.pending = pending
        }
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput,
                             first: CMSampleBuffer?, label: String) async {
        let queue = DispatchQueue(label: "ZoomRecorder.mixdown.\(label)")
        let state = PumpState(output: output, input: input, pending: first)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                guard !state.finished else { return }
                while state.input.isReadyForMoreMediaData {
                    let sample = state.pending ?? state.output.copyNextSampleBuffer()
                    state.pending = nil
                    guard let sample, state.input.append(sample) else {
                        state.finished = true
                        state.input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
