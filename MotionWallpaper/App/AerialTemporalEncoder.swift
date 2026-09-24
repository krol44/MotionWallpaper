import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Produces the temporal HEVC sample groups used by Apple's Aerial player when
/// it slows a movie down during lock/unlock. AVAssetExportSession does not add
/// these groups, even when its HEVC preset is selected.
enum AerialTemporalEncoder {
    enum EncodingError: LocalizedError {
        case unavailable(String)
        case failed(String)
        case noVideoTrack
        case videoTooShort

        var errorDescription: String? {
            switch self {
            case .unavailable(let detail):
                return "This Mac cannot encode a macOS 27 Aerial video: \(detail)"
            case .failed(let detail):
                return "Could not encode a macOS 27 Aerial video: \(detail)"
            case .noVideoTrack:
                return "The selected file has no readable video track."
            case .videoTooShort:
                return "The selected video is too short."
            }
        }
    }

    static func encode(
        source: URL,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw EncodingError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0.1 else {
            throw EncodingError.videoTooShort
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let frameRate = nominalFrameRate >= 2 ? Double(nominalFrameRate) : 30
        guard size.width >= 2, size.height >= 2,
              size.width <= Double(Int32.max), size.height <= Double(Int32.max) else {
            throw EncodingError.unavailable("invalid video dimensions")
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw EncodingError.unavailable("could not create a video track")
        }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        videoTrack.preferredTransform = transform

        let job = EncodingJob(composition: composition, track: videoTrack, progress: progress)
        job.totalDuration = duration.seconds
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionwallpaper-aerial-\(UUID().uuidString).mov")
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try encode(job: job,
                                       width: Int32(size.width), height: Int32(size.height),
                                       frameRate: frameRate, transform: transform, output: output)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                job.cancel()
            }
            try Task.checkCancellation()
            guard hasTemporalSampleGroups(output) else {
                throw EncodingError.failed("the HEVC encoder did not create temporal sample groups")
            }
            progress(1)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // The composition is constructed before dispatch and owned only by the
    // background encoding task afterward; no other thread mutates it.
    private final class EncodingJob: @unchecked Sendable {
        let composition: AVMutableComposition
        let track: AVMutableCompositionTrack
        let progress: (Double) -> Void
        var totalDuration: Double = 0
        private let lock = NSLock()
        private var cancelled = false
        private var reader: AVAssetReader?

        init(composition: AVMutableComposition, track: AVMutableCompositionTrack,
             progress: @escaping (Double) -> Void) {
            self.composition = composition
            self.track = track
            self.progress = progress
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func setReader(_ reader: AVAssetReader) {
            lock.lock()
            self.reader = reader
            let cancelled = self.cancelled
            lock.unlock()
            if cancelled { reader.cancelReading() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let reader = self.reader
            lock.unlock()
            reader?.cancelReading()
        }
    }

    private static func encode(
        job: EncodingJob,
        width: Int32,
        height: Int32,
        frameRate: Double,
        transform: CGAffineTransform,
        output: URL
    ) throws {
        if job.isCancelled { throw CancellationError() }
        let reader = try AVAssetReader(asset: job.composition)
        job.setReader(reader)
        let readerOutput = AVAssetReaderTrackOutput(track: job.track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw EncodingError.unavailable("video reader output") }
        reader.add(readerOutput)

        let sink = SampleWriter(url: output, transform: transform)
        defer { sink.cancelIfNeeded() }
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sample in
                guard let refcon else { return }
                let sink = Unmanaged<SampleWriter>.fromOpaque(refcon).takeUnretainedValue()
                sink.receive(sample, status: status)
            },
            refcon: Unmanaged.passUnretained(sink).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw EncodingError.unavailable("HEVC hardware encoder (\(status))")
        }
        defer { VTCompressionSessionInvalidate(session) }

        func set(_ key: CFString, _ value: CFTypeRef) throws {
            let result = VTSessionSetProperty(session, key: key, value: value)
            guard result == noErr else {
                throw EncodingError.unavailable("encoder property \(key) (\(result))")
            }
        }

        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_AllowTemporalCompression, kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: frameRate))
        try set(kVTCompressionPropertyKey_BaseLayerFrameRate, NSNumber(value: frameRate / 2))
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int(frameRate * 5)))
        try set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: 12_000_000))
        try set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        try set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        try set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)

        let prepare = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepare == noErr else { throw EncodingError.unavailable("prepare encoder (\(prepare))") }
        guard reader.startReading() else {
            if job.isCancelled { throw CancellationError() }
            throw reader.error ?? EncodingError.failed("could not start reading the video")
        }

        var frames = 0
        while let sample = readerOutput.copyNextSampleBuffer() {
            if job.isCancelled { throw CancellationError() }
            if let error = sink.error { throw error }
            guard let image = CMSampleBufferGetImageBuffer(sample) else {
                throw EncodingError.failed("source frame has no image buffer")
            }
            let encodeStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: image,
                presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
                duration: CMSampleBufferGetDuration(sample),
                frameProperties: nil,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )
            guard encodeStatus == noErr else {
                throw EncodingError.failed("frame \(frames) (\(encodeStatus))")
            }
            frames += 1
            if frames % 30 == 0, job.totalDuration > 0 {
                let current = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                job.progress(min(0.99, max(0, current / job.totalDuration)))
            }
        }
        if job.isCancelled { throw CancellationError() }
        guard reader.status == .completed else {
            throw reader.error ?? EncodingError.failed("source video reading stopped")
        }
        guard frames > 0 else { throw EncodingError.failed("source video contains no frames") }
        let finishStatus = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard finishStatus == noErr else {
            throw EncodingError.failed("finishing frames (\(finishStatus))")
        }
        if job.isCancelled { throw CancellationError() }
        try sink.finish()
    }

    private static func hasTemporalSampleGroups(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return data.range(of: Data("tscl".utf8)) != nil &&
            data.range(of: Data("tsas".utf8)) != nil &&
            data.range(of: Data("csgm".utf8)) != nil &&
            data.range(of: Data("sgpd".utf8)) != nil
    }

    private final class SampleWriter {
        private let url: URL
        private let transform: CGAffineTransform
        private let lock = NSLock()
        private var writer: AVAssetWriter?
        private var input: AVAssetWriterInput?
        private var failure: Error?
        private var frameCount = 0

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }

        init(url: URL, transform: CGAffineTransform) {
            self.url = url
            self.transform = transform
        }

        func receive(_ sample: CMSampleBuffer?, status: OSStatus) {
            lock.lock()
            defer { lock.unlock() }
            guard failure == nil else { return }
            guard status == noErr, let sample, CMSampleBufferDataIsReady(sample) else {
                failure = EncodingError.failed("encoded frame callback (\(status))")
                return
            }
            if writer == nil {
                do {
                    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                    guard let format = CMSampleBufferGetFormatDescription(sample) else {
                        throw EncodingError.failed("encoded frame has no format")
                    }
                    let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
                    input.expectsMediaDataInRealTime = false
                    input.transform = transform
                    guard writer.canAdd(input) else {
                        throw EncodingError.failed("could not attach encoded video to output")
                    }
                    writer.add(input)
                    guard writer.startWriting() else {
                        throw writer.error ?? EncodingError.failed("could not start video writer")
                    }
                    writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
                    self.writer = writer
                    self.input = input
                } catch {
                    failure = error
                    return
                }
            }
            guard let input, let writer else { return }
            while !input.isReadyForMoreMediaData && writer.status == .writing {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard writer.status == .writing, input.append(sample) else {
                failure = writer.error ?? EncodingError.failed("could not write encoded frame")
                return
            }
            frameCount += 1
        }

        func finish() throws {
            lock.lock()
            let failure = self.failure
            let writer = self.writer
            let input = self.input
            let frameCount = self.frameCount
            lock.unlock()
            if let failure { throw failure }
            guard frameCount > 0, let writer, let input else {
                throw EncodingError.failed("no encoded frames were written")
            }
            input.markAsFinished()
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            guard writer.status == .completed else {
                throw writer.error ?? EncodingError.failed("the video writer did not finish")
            }
        }

        func cancelIfNeeded() {
            lock.lock()
            let writer = self.writer
            lock.unlock()
            if writer?.status == .writing { writer?.cancelWriting() }
        }
    }
}
