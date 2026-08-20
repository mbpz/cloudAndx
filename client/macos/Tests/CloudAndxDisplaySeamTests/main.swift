import CloudAndxClientCore
import CryptoKit
import CoreGraphics
import CoreVideo
import Foundation
import Metal
import VideoToolbox

@main
enum CloudAndxDisplaySeamTests {
    static func main() throws {
        try parserAndControlTests()
        let decoderAvailable = h264DecoderAvailable()
        try endpointTests(decoderAvailable: decoderAvailable)
        try h264RoundTripFixture(decoderAvailable: decoderAvailable)
        print("PASS: CloudAndx display seam tests")
    }
    static func be32(_ n: UInt32) -> Data { Data([UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]) }
    static func be64(_ n: UInt64) -> Data { be32(UInt32(truncatingIfNeeded: n >> 32)) + be32(UInt32(truncatingIfNeeded: n)) }
    static func expect(_ condition: @autoclosure () -> Bool, _ text: String) throws { if !condition() { throw Failure(text) } }
    static func expectDisplayError(_ expected: ScrcpyDisplayError, _ text: String, _ body: () throws -> Void) throws {
        do {
            try body()
            throw Failure(text)
        } catch let error as ScrcpyDisplayError {
            try expect(error == expected, "\\(text): \\(error)")
        }
    }
    static func parserAndControlTests() throws {
        let parser = ScrcpyVideoParser(); var stream = Data("h264".utf8) + be32(0x80000000) + be32(64) + be32(32)
        stream += be64((1 << 62) | (1 << 61) | 9) + be32(1) + Data([7])
        _ = try parser.feed(stream.prefix(3)); let frames = try parser.feed(Data(stream.dropFirst(3)))
        try expect(frames.count == 1 && frames[0].timestamp == 9 && frames[0].isConfiguration && frames[0].isKeyFrame, "fragmented v4.1 media framing")
        let touch = try ScrcpyControl.touch(.down, x: 100, y: 200, width: 1080, height: 1920, pointerID: 0x1234567887654321)
        let scroll = try ScrcpyControl.scroll(x: 260, y: 1026, width: 1080, height: 1920, horizontal: 16, vertical: -16, buttons: 1)
        try expect(touch.encoded == Data([0x02,0x00,0x12,0x34,0x56,0x78,0x87,0x65,0x43,0x21,0,0,0,0x64,0,0,0,0xc8,0x04,0x38,0x07,0x80,0xff,0xff,0,0,0,1,0,0,0,1]), "official touch down golden bytes")
        try expect(scroll.encoded == Data([0x03,0,0,1,0x04,0,0,4,0x02,0x04,0x38,0x07,0x80,0x7f,0xff,0x80,0,0,0,0,1]), "official scroll golden bytes")
        try expect(ScrcpyControl.key(action: .up, keyCode: 0x42, repeatCount: 5, metaState: 0x41).encoded == Data([0,1,0,0,0,0x42,0,0,0,5,0,0,0,0x41]), "official key golden bytes")
        try expectDisplayError(.invalidControl, "zero-sized touch accepted") { _ = try ScrcpyControl.touch(.down, x: 0, y: 0, width: 0, height: 1) }
        try expectDisplayError(.invalidControl, "oversized scroll accepted") { _ = try ScrcpyControl.scroll(x: 0, y: 0, width: 65_536, height: 1, horizontal: 0, vertical: 0) }

        try expectDisplayError(.malformedHeader, "zero video dimensions accepted") {
            _ = try ScrcpyVideoParser().feed(Data("h264".utf8) + be32(0x8000_0000) + be32(0) + be32(1))
        }
        try expectDisplayError(.malformedHeader, "invalid metadata flags accepted") {
            _ = try ScrcpyVideoParser().feed(Data("h264".utf8) + be32(0x8000_0002) + be32(1) + be32(1))
        }
        let boundary = ScrcpyVideoParser()
        _ = try boundary.feed(Data("h264".utf8) + be32(0x8000_0000) + be32(1) + be32(1) + be64(0) + be32(1))
        try expectDisplayError(.truncated, "partial packet accepted at EOF") { try boundary.finish() }
        try expectDisplayError(.stopped, "parser accepted bytes after EOF") { _ = try boundary.feed(Data()) }

        let largest = ScrcpyVideoParser()
        let largestHeader = Data("h264".utf8) + be32(0x8000_0000) + be32(1) + be32(1) + be64(0) + be32(UInt32(ScrcpyVideoParser.maxPacketBytes))
        let largestInitial = try largest.feed(largestHeader)
        try expect(largestInitial.isEmpty, "maximum packet header emitted early")
        let largestPackets = try largest.feed(Data(repeating: 0x65, count: ScrcpyVideoParser.maxPacketBytes))
        try expect(largestPackets.count == 1 && largestPackets[0].payload.count == ScrcpyVideoParser.maxPacketBytes, "exact maximum packet rejected")
        let onePast = ScrcpyVideoParser()
        try expectDisplayError(.oversizedPacket, "one-byte-over packet accepted") {
            _ = try onePast.feed(Data("h264".utf8) + be32(0x8000_0000) + be32(1) + be32(1) + be64(0) + be32(UInt32(ScrcpyVideoParser.maxPacketBytes + 1)))
        }

        let geometry = ScrcpyPresentationGeometry(source: CGSize(width: 1080, height: 2400), destination: CGSize(width: 1200, height: 800))
        try expect(geometry.rect == CGRect(x: 420, y: 0, width: 360, height: 800), "presentation aspect-fit rectangle drift")
        let mappedOrigin = ScrcpyCoordinateMapper(source: geometry.source, view: geometry.destination).map(geometry.rect.origin)
        let mappedEnd = ScrcpyCoordinateMapper(source: geometry.source, view: geometry.destination).map(CGPoint(x: geometry.rect.maxX, y: geometry.rect.maxY))
        try expect(mappedOrigin == .zero && mappedEnd == CGPoint(x: 1079, y: 2399), "presentation and touch geometry disagree")
    }
    static func endpointTests(decoderAvailable: Bool) throws {
        var initialVideo = [Int32](repeating: -1, count: 2); var initialControl = [Int32](repeating: -1, count: 2)
        var video = [Int32](repeating: -1, count: 2); var control = [Int32](repeating: -1, count: 2)
        guard pipe(&initialVideo) == 0, pipe(&initialControl) == 0, pipe(&video) == 0, pipe(&control) == 0 else { throw Failure("pipe") }
        let session = ScrcpyDisplaySession()
        try session.attach(video: FileHandle(fileDescriptor: initialVideo[0], closeOnDealloc: true), control: FileHandle(fileDescriptor: initialControl[1], closeOnDealloc: true))
        try session.attach(video: FileHandle(fileDescriptor: video[0], closeOnDealloc: true), control: FileHandle(fileDescriptor: control[1], closeOnDealloc: true))
        close(initialVideo[1]); close(initialControl[0])
        try expect(session.state == .negotiating && session.endpointState == .init(videoAttached: true, controlAttached: true), "replacement did not transfer endpoint ownership")
        let header = Data("h264".utf8) + be32(0x80000000) + be32(16) + be32(16)
        header.withUnsafeBytes { _ = Darwin.write(video[1], $0.baseAddress!, header.count) }; close(video[1])
        try session.readAvailable()
        try expect(session.videoConfiguration?.width == 16 && session.state == .negotiating, "pipe-backed header read drift")
        if decoderAvailable {
            let evidence = try decodeAndAssert(configuration: auditedConfigurationFixture, frame: auditedIDRFixture)
            try session.presentDecodedFrame(evidence); try session.sendControl(ScrcpyControl.navigationHomeDown())
            var result = [UInt8](repeating: 0, count: 14); try expect(Darwin.read(control[0], &result, 14) == 14 && result == Array(ScrcpyControl.navigationHomeDown().encoded), "control endpoint write")
        }
        close(control[0]); try session.readAvailable()
        try expect(session.state == .stopped && session.endpointState == .init(videoAttached: false, controlAttached: false), "EOF ownership cleanup")
    }
    static func h264RoundTripFixture(decoderAvailable: Bool) throws {
        let pixel = try cpuPixelBuffer(width: 16, height: 16)
        CVPixelBufferLockBaseAddress(pixel, []); defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        memset(CVPixelBufferGetBaseAddress(pixel), 0x2a, CVPixelBufferGetDataSize(pixel))
        let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let checksum = (0 ..< CVPixelBufferGetDataSize(pixel)).reduce(0) { $0 + Int(bytes[$1]) }
        try expect(CVPixelBufferGetWidth(pixel) == 16 && CVPixelBufferGetHeight(pixel) == 16 && checksum == CVPixelBufferGetDataSize(pixel) * 42, "deterministic CPU-backed BGRA fixture")
        let combinedFixture = auditedConfigurationFixture + auditedIDRFixture
        let digest = SHA256.hash(data: combinedFixture).map { String(format: "%02x", $0) }.joined()
        try expect(digest == "5ce781747c676c8e417e3a3a70abf97daf030440e3068c721873702ebc2435f8", "audited Annex-B fixture digest drift")
        guard decoderAvailable else {
            try renderOffscreen(try opaqueFixturePixelBuffer())
            return
        }
        let decoded = try decodeAndAssert(configuration: auditedConfigurationFixture, frame: auditedIDRFixture)
        let encodeAttempt = try encodeWithVideoToolbox(pixel)
        if let encoded = encodeAttempt.annexB { _ = try decodeAndAssert(configuration: encoded.configuration, frame: encoded.frame) }
        else { print("INFO: VideoToolbox H264 encoder unavailable (OSStatus " + String(encodeAttempt.status) + "); fixed vector decode remains strict") }
        try renderOffscreen(try opaqueFixturePixelBuffer())
        try expect(CVPixelBufferGetPixelFormatType(decoded.pixelBuffer) == kCVPixelFormatType_32BGRA, "decoded fixture pixel format drift")
    }

    static func h264DecoderAvailable() -> Bool {
        do {
            let decoder = ScrcpyH264Decoder()
            try decoder.configure(annexB: auditedConfigurationFixture)
            return true
        } catch let ScrcpyDisplayError.videoToolbox(status) where [-12906, -12909, -12910, -12911, -12913].contains(status) {
            fputs("INFO: VideoToolbox H264 decoder unavailable (OSStatus \(status)); decode assertions skipped\n", stderr)
            return false
        } catch {
            fatalError("unexpected H264 decoder setup failure: \(error)")
        }
    }

    static func decodeAndAssert(configuration: Data, frame: Data) throws -> ScrcpyDecodedFrame {
        let decoder = ScrcpyH264Decoder()
        try decoder.configure(annexB: configuration)
        try decoder.decode(annexB: frame, timestamp: 0)
        let decoded = try decoder.finishFrames()
        try expect(CVPixelBufferGetWidth(decoded.pixelBuffer) == 16 && CVPixelBufferGetHeight(decoded.pixelBuffer) == 16, "decoded fixture dimensions")
        try expect(CVPixelBufferGetPixelFormatType(decoded.pixelBuffer) == kCVPixelFormatType_32BGRA, "decoded frame is not BGRA")
        CVPixelBufferLockBaseAddress(decoded.pixelBuffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(decoded.pixelBuffer, .readOnly) }
        let decodedBytes = CVPixelBufferGetBaseAddress(decoded.pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(decoded.pixelBuffer)
        var decodedChecksum = 0; var minimumChannel = 255; var maximumChannel = 0
        for y in 0 ..< 16 {
            for x in 0 ..< 16 {
                for channel in 0 ..< 3 {
                    let value = Int(decodedBytes[y * rowBytes + x * 4 + channel])
                    decodedChecksum += value; minimumChannel = min(minimumChannel, value); maximumChannel = max(maximumChannel, value)
                }
            }
        }
        try expect(minimumChannel >= 30 && maximumChannel <= 60 && decodedChecksum >= 23_040 && decodedChecksum <= 46_080, "decoded solid-frame channel/checksum evidence")
        try expectDisplayError(.malformedHeader, "bad decode frame accepted") { try decoder.decode(annexB: Data(), timestamp: 1) }
        try decoder.configure(annexB: configuration)
        try expectDisplayError(.malformedHeader, "invalid reconfiguration accepted") { try decoder.configure(annexB: Data()) }
        try expect(decoder.formatDescription == nil, "invalid reconfigure retained decoder state")
        return decoded
    }

    static func cpuPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        let attributes: CFDictionary = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &pixel) == kCVReturnSuccess, let pixel else { throw Failure("CPU-backed BGRA pixel buffer") }
        CVPixelBufferLockBaseAddress(pixel, []); defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        memset(CVPixelBufferGetBaseAddress(pixel), 0x2a, CVPixelBufferGetDataSize(pixel))
        return pixel
    }

    static func opaqueFixturePixelBuffer() throws -> CVPixelBuffer {
        let pixel = try cpuPixelBuffer(width: 16, height: 16)
        CVPixelBufferLockBaseAddress(pixel, []); defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        for offset in stride(from: 3, to: CVPixelBufferGetDataSize(pixel), by: 4) { bytes[offset] = 255 }
        return pixel
    }

    static func renderOffscreen(_ pixel: CVPixelBuffer) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = ScrcpyPixelBufferRenderer(device: device), let queue = device.makeCommandQueue() else {
            fputs("INFO: Metal unavailable; offscreen render assertions skipped\n", stderr)
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 32, mipmapped: false); descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else { throw Failure("offscreen texture unavailable") }
        renderer.render(pixelBuffer: pixel, to: texture, commandBuffer: command); command.commit(); command.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: 64 * 32 * 4); texture.getBytes(&bytes, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0)
        let letterbox = bytes[(16 * 64 + 0) * 4]; let center = bytes[(16 * 64 + 32) * 4]; let maximum = bytes.max() ?? 0
        try expect(letterbox == 0 && center >= 30 && center <= 60, "offscreen renderer did not preserve black letterbox and colored center: " + String(letterbox) + ", " + String(center) + ", max=" + String(maximum))
    }

    /// The encode path is exercised whenever VideoToolbox offers an encoder.
    /// Sandboxed CI can deny encoder discovery, so decode coverage has an
    /// audited, deterministic Annex-B fallback below.
    static func encodeWithVideoToolbox(_ pixel: CVPixelBuffer) throws -> (annexB: (configuration: Data, frame: Data)?, status: OSStatus) {
        let encoded = EncodedFrame(); var compression: VTCompressionSession?
        let softwareEncoder: CFDictionary = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: false,
        ] as CFDictionary
        let create = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 16, height: 16, codecType: kCMVideoCodecType_H264, encoderSpecification: softwareEncoder, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { refcon, _, status, _, sample in
            guard status == noErr, let sample, let refcon else { return }
            let box = Unmanaged<EncodedFrame>.fromOpaque(refcon).takeUnretainedValue(); box.capture(sample)
        }, refcon: Unmanaged.passUnretained(encoded).toOpaque(), compressionSessionOut: &compression)
        guard create == noErr, let compression else { return (nil, create) }
        defer { VTCompressionSessionInvalidate(compression) }
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        guard VTCompressionSessionPrepareToEncodeFrames(compression) == noErr, VTCompressionSessionEncodeFrame(compression, imageBuffer: pixel, presentationTimeStamp: .zero, duration: .invalid, frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary, sourceFrameRefcon: nil, infoFlagsOut: nil) == noErr, VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid) == noErr, encoded.wait() else { throw Failure("VideoToolbox H264 fixture encode") }
        return ((encoded.configuration, encoded.frame), create)
    }

    /// SHA-256: 5ce781747c676c8e417e3a3a70abf97daf030440e3068c721873702ebc2435f8
    /// Provenance is recorded in docs/native-macos-embedded-display.md.
    static let auditedConfigurationFixture = Data(base64Encoded: "AAAAAWdCwArd7ARAAAADAEAAAAMAg8SJ4AAAAAFozg8sgA==")!
    static let auditedIDRFixture = Data(base64Encoded: "AAABZYiEBLyYoAAwo4A=")!
}
final class EncodedFrame: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0); private(set) var configuration = Data(); private(set) var frame = Data()
    func capture(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample), let buffer = CMSampleBufferGetDataBuffer(sample) else { return }
        var count: Int = 0; var nalLength: Int32 = 0; var sps: UnsafePointer<UInt8>?; var spsSize = 0; var pps: UnsafePointer<UInt8>?; var ppsSize = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &sps, parameterSetSizeOut: &spsSize, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength) == noErr, CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1, parameterSetPointerOut: &pps, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let sps, let pps else { return }
        configuration = Data([0,0,0,1]) + Data(bytes: sps, count: spsSize) + Data([0,0,0,1]) + Data(bytes: pps, count: ppsSize)
        var length = 0; var pointer: UnsafeMutablePointer<Int8>?; guard CMBlockBufferGetDataPointer(buffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { return }
        var offset = 0; let raw = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        while offset + 4 <= length { let n = Int(raw[offset]) << 24 | Int(raw[offset+1]) << 16 | Int(raw[offset+2]) << 8 | Int(raw[offset+3]); guard n > 0, offset + 4 + n <= length else { return }; frame.append(Data([0,0,0,1])); frame.append(Data(bytes: raw + offset + 4, count: n)); offset += 4 + n }
        semaphore.signal()
    }
    func wait() -> Bool { semaphore.wait(timeout: .now() + 5) == .success && !configuration.isEmpty && !frame.isEmpty }
}
struct Failure: Error, CustomStringConvertible { let text: String; init(_ text: String) { self.text = text }; var description: String { text } }
