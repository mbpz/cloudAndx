import CoreGraphics
import CoreImage
import Darwin
import Foundation
import Metal
import VideoToolbox

/// Phase 2D1 fixture seam. It accepts only already-open endpoints: discovery,
/// ADB, server launch, socket creation, and lifecycle authority stay outside it.
///
/// scrcpy 4.1 source pin: 2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0.
/// Documented server args for this seam are `send_device_meta=false`,
/// `send_codec_meta=true`, and v4.1 frame/session metadata enabled. v4.1 raw
/// video stream starts with a u32 BE codec id, then the 12-byte v4.1
/// session metadata `[flags u32 BE, width u32 BE, height u32 BE]`; flags use
/// MSB for a session packet and LSB for a resized stream. Media then
/// repeats `[ptsAndFlags u64 BE, payloadLength u32 BE, payload]`. Bit 63
/// discriminates session metadata; for media, CONFIG is bit 62 and KEY_FRAME
/// is bit 61. This is an audited protocol fact from the pinned source, not
/// copied server code.
public enum ScrcpyDisplayState: Equatable, Sendable { case disconnected, negotiating, rendering, failed, stopped }
public enum ScrcpyDisplayError: Error, Equatable, Sendable {
    case malformedHeader, unsupportedCodec(String), oversizedPacket, truncated, queueFull, stopped, invalidControl, invalidEndpoint, invalidFrame, videoToolbox(Int32)
}

public struct ScrcpyVideoConfiguration: Equatable, Sendable {
    public let deviceName: String
    public let codec: String
    public let width: Int
    public let height: Int
    public init(deviceName: String, codec: String, width: Int, height: Int) { self.deviceName = deviceName; self.codec = codec; self.width = width; self.height = height }
}

public struct ScrcpyVideoPacket: Equatable, Sendable {
    public let timestamp: UInt64
    public let isConfiguration: Bool
    public let isKeyFrame: Bool
    public let payload: Data
    public init(timestamp: UInt64, isConfiguration: Bool, isKeyFrame: Bool, payload: Data) { self.timestamp = timestamp; self.isConfiguration = isConfiguration; self.isKeyFrame = isKeyFrame; self.payload = payload }
}

/// Decoder-produced presentation evidence. The initializer is intentionally
/// file-private so endpoint sessions cannot be promoted by fabricated buffers.
public struct ScrcpyDecodedFrame {
    public let pixelBuffer: CVPixelBuffer
    fileprivate init(pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}

/// Bounded, incremental parser; callers feed arbitrary fragmented endpoint reads.
public final class ScrcpyVideoParser {
    public static let headerBytes = 16
    public static let maxPacketBytes = 8 * 1024 * 1024
    public static let maxBufferedBytes = maxPacketBytes + headerBytes + 12
    public static let maxRecordsPerFeed = 64
    private static let configFlag: UInt64 = 1 << 62
    private static let keyFrameFlag: UInt64 = 1 << 61
    private var bytes = Data()
    private var cursor = 0
    private var configuration: ScrcpyVideoConfiguration?
    private var ended = false

    public init() {}
    public func reset() { bytes.removeAll(keepingCapacity: true); cursor = 0; configuration = nil; ended = false }

    public func feed(_ chunk: Data, maximumPackets: Int = maxRecordsPerFeed) throws -> [ScrcpyVideoPacket] {
        guard !ended else { throw ScrcpyDisplayError.stopped }
        guard maximumPackets > 0 else { throw ScrcpyDisplayError.queueFull }
        guard chunk.count <= Self.maxBufferedBytes, availableBytes <= Self.maxBufferedBytes - chunk.count else { throw ScrcpyDisplayError.oversizedPacket }
        bytes.append(chunk)
        var output = [ScrcpyVideoPacket]()
        var records = 0
        defer { compactIfNeeded() }
        if configuration == nil {
            guard availableBytes >= Self.headerBytes else { return output }
            let codec = String(bytes: bytes[cursor ..< cursor + 4], encoding: .ascii) ?? ""
            guard codec == "h264" else { throw ScrcpyDisplayError.unsupportedCodec(codec) }
            let flags = Self.u32(bytes, 4)
            guard flags & ~UInt32(0x8000_0001) == 0, flags & UInt32(0x8000_0000) != 0 else { throw ScrcpyDisplayError.malformedHeader }
            let width = Int(Self.u32(bytes, 8)); let height = Int(Self.u32(bytes, 12))
            guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { throw ScrcpyDisplayError.malformedHeader }
            // Device metadata is disabled for this narrow stream profile, so
            // this is a local endpoint label, not server-supplied metadata.
            configuration = .init(deviceName: "endpoint", codec: codec, width: width, height: height)
            consume(Self.headerBytes)
        }
        while availableBytes >= 12, records < Self.maxRecordsPerFeed, output.count < maximumPackets {
            // Session packets are distinguishable by the MSB in their first
            // u32. They may recur after a rotated/resized stream.
            if bytes[cursor] & 0x80 != 0 {
                let flags = Self.u32(bytes, cursor); let width = Int(Self.u32(bytes, cursor + 4)); let height = Int(Self.u32(bytes, cursor + 8))
                guard flags & ~UInt32(0x8000_0001) == 0, width > 0, height > 0, width <= 16_384, height <= 16_384 else { throw ScrcpyDisplayError.malformedHeader }
                let old = configuration!
                configuration = .init(deviceName: old.deviceName, codec: old.codec, width: width, height: height)
                consume(12); records += 1; continue
            }
            let taggedPTS = Self.u64(bytes, cursor)
            let length = Int(Self.u32(bytes, cursor + 8))
            guard length > 0, length <= Self.maxPacketBytes else { throw ScrcpyDisplayError.oversizedPacket }
            guard availableBytes >= 12 + length else { return output }
            let body = Data(bytes[(cursor + 12) ..< (cursor + 12 + length)]); consume(12 + length)
            let timestamp = taggedPTS & ~(Self.configFlag | Self.keyFrameFlag)
            let config = taggedPTS & Self.configFlag != 0
            let key = taggedPTS & Self.keyFrameFlag != 0
            output.append(.init(timestamp: timestamp, isConfiguration: config, isKeyFrame: key, payload: body))
            records += 1
        }
        return output
    }

    public func finish() throws {
        ended = true
        if availableBytes != 0 { throw ScrcpyDisplayError.truncated }
    }
    public var videoConfiguration: ScrcpyVideoConfiguration? { configuration }
    public var bufferedBytes: Int { availableBytes }
    private var availableBytes: Int { bytes.count - cursor }
    private func consume(_ count: Int) { cursor += count }
    private func compactIfNeeded() { if cursor == bytes.count { bytes.removeAll(keepingCapacity: true); cursor = 0 } else if cursor >= 64 * 1024 { bytes = Data(bytes.dropFirst(cursor)); cursor = 0 } }
    private static func u32(_ data: Data, _ at: Int) -> UInt32 { data[at ..< at + 4].reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func u64(_ data: Data, _ at: Int) -> UInt64 { data[at ..< at + 8].reduce(0) { ($0 << 8) | UInt64($1) } }
}

public final class ScrcpyPacketQueue {
    private let limit: Int; private var storage = [ScrcpyVideoPacket](); private let lock = NSLock()
    public init(limit: Int = 8) { self.limit = max(1, limit) }
    public func push(_ packet: ScrcpyVideoPacket) throws { lock.lock(); defer { lock.unlock() }; guard storage.count < limit else { throw ScrcpyDisplayError.queueFull }; storage.append(packet) }
    public func pop() -> ScrcpyVideoPacket? { lock.lock(); defer { lock.unlock() }; return storage.isEmpty ? nil : storage.removeFirst() }
    public func reset() { lock.lock(); storage.removeAll(); lock.unlock() }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
    public var remainingCapacity: Int { lock.lock(); defer { lock.unlock() }; return limit - storage.count }
}

/// Endpoint ownership and replacement are explicit. No pathname or socket API is exposed.
public final class ScrcpyDisplaySession {
    public private(set) var state: ScrcpyDisplayState = .disconnected
    private var parser = ScrcpyVideoParser()
    private var videoEndpoint: FileHandle?
    private var controlEndpoint: FileHandle?
    public private(set) var endpointState = ScrcpyEndpointState(videoAttached: false, controlAttached: false)
    private let packets = ScrcpyPacketQueue()
    public var videoConfiguration: ScrcpyVideoConfiguration? { parser.videoConfiguration }
    public var queuedPacketCount: Int { packets.count }
    public init() {}
    public func attach(video: FileHandle, control: FileHandle) throws {
        let ownedVideo = try ownedEndpoint(video, readable: true)
        do {
            let ownedControl = try ownedEndpoint(control, readable: false)
            teardown(); videoEndpoint = ownedVideo; controlEndpoint = ownedControl; endpointState = .init(videoAttached: true, controlAttached: true); parser.reset(); state = .negotiating
        } catch { try? ownedVideo.close(); throw error }
    }
    private func ingest(_ data: Data) throws {
        let remaining = packets.remainingCapacity
        guard remaining > 0 else { throw ScrcpyDisplayError.queueFull }
        for packet in try parser.feed(data, maximumPackets: remaining) { try packets.push(packet) }
    }
    public func dequeuePacket() -> ScrcpyVideoPacket? { packets.pop() }
    /// Rendering requires actual decoded-frame evidence with negotiated dimensions.
    public func presentDecodedFrame(_ frame: ScrcpyDecodedFrame) throws {
        guard let configuration = parser.videoConfiguration,
              CVPixelBufferGetWidth(frame.pixelBuffer) == configuration.width,
              CVPixelBufferGetHeight(frame.pixelBuffer) == configuration.height
        else { state = .failed; throw ScrcpyDisplayError.invalidFrame }
        state = .rendering
    }
    /// Reads one bounded chunk from the already-open video descriptor. It never
    /// opens a path, resolves a socket, starts a server, or executes a process.
    public func readAvailable(limit: Int = 64 * 1024) throws {
        guard let videoEndpoint, limit > 0, limit <= ScrcpyVideoParser.maxPacketBytes else { throw ScrcpyDisplayError.stopped }
        if parser.bufferedBytes > 0 {
            let bufferedBefore = parser.bufferedBytes; let queuedBefore = packets.count
            try ingest(Data())
            if parser.bufferedBytes < bufferedBefore || packets.count > queuedBefore { return }
        }
        let data = try videoEndpoint.read(upToCount: limit) ?? Data()
        if data.isEmpty { eof() } else { try ingest(data) }
    }
    /// Control serialization is typed: raw arbitrary Data never crosses the
    /// display boundary.
    public func sendControl(_ message: ScrcpyControlMessage) throws {
        guard state == .rendering, let controlEndpoint else { throw ScrcpyDisplayError.stopped }
        try controlEndpoint.write(contentsOf: message.encoded)
    }
    public func eof() { do { try parser.finish(); state = .stopped } catch { state = .failed }; teardownEndpoints() }
    public func teardown() { parser.reset(); packets.reset(); teardownEndpoints(); state = .disconnected }
    private func ownedEndpoint(_ endpoint: FileHandle, readable: Bool) throws -> FileHandle {
        let descriptor = endpoint.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        var info = stat()
        let typeOK = fstat(descriptor, &info) == 0 && ((info.st_mode & S_IFMT) == S_IFIFO || (info.st_mode & S_IFMT) == S_IFSOCK)
        let access = flags & O_ACCMODE
        guard flags >= 0, typeOK, (readable ? access != O_WRONLY : access != O_RDONLY) else { try? endpoint.close(); throw ScrcpyDisplayError.invalidEndpoint }
        let duplicate = dup(descriptor)
        try? endpoint.close()
        guard duplicate >= 0 else { throw ScrcpyDisplayError.invalidEndpoint }
        return FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
    }
    private func teardownEndpoints() { try? videoEndpoint?.close(); try? controlEndpoint?.close(); videoEndpoint = nil; controlEndpoint = nil; endpointState = .init(videoAttached: false, controlAttached: false) }
}

public struct ScrcpyEndpointState: Equatable, Sendable { public let videoAttached: Bool; public let controlAttached: Bool; public init(videoAttached: Bool, controlAttached: Bool) { self.videoAttached = videoAttached; self.controlAttached = controlAttached } }

public struct ScrcpyControlMessage: Equatable, Sendable {
    public let encoded: Data
    fileprivate init(_ encoded: Data) { self.encoded = encoded }
}

public enum ScrcpyControl {
    public enum Action: UInt8 { case down = 0, up = 1, move = 2 }
    public enum KeyAction: UInt8 { case down = 0, up = 1 }
    /// scrcpy control message types: inject touch=2, scroll=3, keycode=0.
    public static func touch(_ action: Action, x: Int, y: Int, width: Int, height: Int, pointerID: UInt64 = 0) throws -> ScrcpyControlMessage {
        let size = try dimensions(width, height); var d = Data([2, action.rawValue]); d.append(be64(pointerID)); d.append(be32(UInt32(clamp(x, 0, width - 1)))); d.append(be32(UInt32(clamp(y, 0, height - 1)))); d.append(be16(size.0)); d.append(be16(size.1)); d.append(be16(action == .up ? 0 : 0xffff)); d.append(be32(action == .move ? 0 : 1)); d.append(be32(action == .up ? 0 : 1)); return .init(d)
    }
    /// Server accepts [-16,16], encoded as a normalized signed i16 fixed value.
    public static func scroll(x: Int, y: Int, width: Int, height: Int, horizontal: Int, vertical: Int, buttons: UInt32 = 0) throws -> ScrcpyControlMessage { let size = try dimensions(width, height); var d = Data([3]); d.append(be32(UInt32(clamp(x, 0, width - 1)))); d.append(be32(UInt32(clamp(y, 0, height - 1)))); d.append(be16(size.0)); d.append(be16(size.1)); d.append(be16(UInt16(bitPattern: normalizedScroll(horizontal)))); d.append(be16(UInt16(bitPattern: normalizedScroll(vertical)))); d.append(be32(buttons)); return .init(d) }
    public static func key(action: KeyAction, keyCode: UInt32, repeatCount: UInt32 = 0, metaState: UInt32 = 0) -> ScrcpyControlMessage { var d = Data([0, action.rawValue]); d.append(be32(keyCode)); d.append(be32(repeatCount)); d.append(be32(metaState)); return .init(d) }
    /// Deliberately down-only. Callers needing a press must send a matching up.
    public static func navigationHomeDown() -> ScrcpyControlMessage { key(action: .down, keyCode: 3) }
    private static func clamp(_ n: Int, _ low: Int, _ high: Int) -> Int { min(max(n, low), max(low, high)) }
    private static func dimensions(_ width: Int, _ height: Int) throws -> (UInt16, UInt16) { guard width > 0, height > 0, width <= Int(UInt16.max), height <= Int(UInt16.max) else { throw ScrcpyDisplayError.invalidControl }; return (UInt16(width), UInt16(height)) }
    private static func normalizedScroll(_ value: Int) -> Int16 { let n = clamp(value, -16, 16); return n == -16 ? Int16.min : Int16((n * Int(Int16.max)) / 16) }
    private static func be16(_ n: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]) }
    private static func be32(_ n: UInt32) -> Data { Data([UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]) }
    private static func be64(_ n: UInt64) -> Data { be32(UInt32(truncatingIfNeeded: n >> 32)) + be32(UInt32(truncatingIfNeeded: n)) }
}

/// Decoder owns VideoToolbox state only. It needs an H.264 configuration packet
/// before media; unsupported/truncated data leaves it failed rather than drawing
/// guessed pixels. The fixture UI intentionally does not instantiate this class.
public final class ScrcpyH264Decoder {
    public private(set) var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private let lock = NSLock()
    private var storedPixelBuffer: CVPixelBuffer?
    private var callbackError: OSStatus?
    public init() {}
    deinit { reset() }
    public func configure(annexB: Data) throws {
        reset()
        let nals = annexBNALs(annexB); guard let sps = nals.first(where: { $0.first.map { $0 & 0x1f == 7 } ?? false }), let pps = nals.first(where: { $0.first.map { $0 & 0x1f == 8 } ?? false }) else { throw ScrcpyDisplayError.malformedHeader }
        var desc: CMFormatDescription?
        let status = sps.withUnsafeBytes { sp in pps.withUnsafeBytes { pp in
            let spBytes = sp.bindMemory(to: UInt8.self); let ppBytes = pp.bindMemory(to: UInt8.self)
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: [spBytes.baseAddress!, ppBytes.baseAddress!], parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
        } }
        guard status == noErr, let description = desc else { throw ScrcpyDisplayError.videoToolbox(status) }
        formatDescription = description
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { refcon, _, status, _, imageBuffer, _, _ in
            guard let refcon else { return }
            let decoder = Unmanaged<ScrcpyH264Decoder>.fromOpaque(refcon).takeUnretainedValue()
            decoder.lock.lock()
            if status == noErr, let imageBuffer { decoder.storedPixelBuffer = imageBuffer } else { decoder.callbackError = status; decoder.storedPixelBuffer = nil }
            decoder.lock.unlock()
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var newSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary, outputCallback: &callback, decompressionSessionOut: &newSession)
        guard sessionStatus == noErr else { reset(); throw ScrcpyDisplayError.videoToolbox(sessionStatus) }
        session = newSession
    }
    /// Decodes one Annex-B access unit into a VideoToolbox pixel buffer.
    public func decode(annexB: Data, timestamp: UInt64) throws {
        clearLatestFrame()
        do {
            guard let formatDescription, let session else { throw ScrcpyDisplayError.malformedHeader }
            let avcc = try annexBToAVCC(annexB); var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr, let block else { throw ScrcpyDisplayError.malformedHeader }
            let write = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
            guard write == noErr else { throw ScrcpyDisplayError.malformedHeader }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(timestamp), timescale: 1_000_000), decodeTimeStamp: .invalid); var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: [avcc.count], sampleBufferOut: &sample) == noErr, let sample else { throw ScrcpyDisplayError.malformedHeader }
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
            guard status == noErr else { throw ScrcpyDisplayError.videoToolbox(status) }
        } catch { clearLatestFrame(); throw error }
    }
    /// Flush delayed output before waiting so callers can safely inspect the
    /// latest decoded buffer after a finite fixture/access unit sequence.
    public func finishFrames() throws -> ScrcpyDecodedFrame {
        guard let session else { throw ScrcpyDisplayError.malformedHeader }
        let finishStatus = VTDecompressionSessionFinishDelayedFrames(session)
        guard finishStatus == noErr else { clearLatestFrame(); throw ScrcpyDisplayError.videoToolbox(finishStatus) }
        let waitStatus = VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard waitStatus == noErr else { clearLatestFrame(); throw ScrcpyDisplayError.videoToolbox(waitStatus) }
        lock.lock(); let error = callbackError; let frame = storedPixelBuffer; lock.unlock()
        if let error { clearLatestFrame(); throw error == noErr ? ScrcpyDisplayError.invalidFrame : ScrcpyDisplayError.videoToolbox(error) }
        guard let frame else { clearLatestFrame(); throw ScrcpyDisplayError.invalidFrame }
        return ScrcpyDecodedFrame(pixelBuffer: frame)
    }
    public func reset() { if let session { VTDecompressionSessionInvalidate(session) }; session = nil; formatDescription = nil; clearLatestFrame() }
    private func clearLatestFrame() { lock.lock(); storedPixelBuffer = nil; callbackError = nil; lock.unlock() }
    private func annexBNALs(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts = [(offset: Int, prefix: Int)]()
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3)); index += 3
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4)); index += 4
            } else {
                index += 1
            }
        }
        return starts.enumerated().compactMap { position, start in
            let end = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            let payloadStart = start.offset + start.prefix
            return payloadStart < end ? Data(bytes[payloadStart ..< end]) : nil
        }
    }
    private func annexBToAVCC(_ data: Data) throws -> Data { let nals = annexBNALs(data); guard !nals.isEmpty else { throw ScrcpyDisplayError.malformedHeader }; return nals.reduce(into: Data()) { output, nal in let count = UInt32(nal.count); output.append(Data([UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16), UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)])); output.append(nal) } }
}

public struct ScrcpyCoordinateMapper: Equatable, Sendable {
    public enum Rotation: Int, Sendable { case degrees0, degrees90, degrees180, degrees270 }
    public let source: CGSize; public let view: CGSize; public let rotation: Rotation
    public init(source: CGSize, view: CGSize, rotation: Rotation = .degrees0) { self.source = source; self.view = view; self.rotation = rotation }
    public func map(_ point: CGPoint) -> CGPoint {
        guard source.width > 0, source.height > 0, view.width > 0, view.height > 0 else { return .zero }
        let rotated = rotation == .degrees90 || rotation == .degrees270 ? CGSize(width: source.height, height: source.width) : source
        let mapped = ScrcpyPresentationGeometry(source: rotated, destination: view).map(point)
        let x = mapped.x; let y = mapped.y
        switch rotation { case .degrees0: return .init(x: x, y: y); case .degrees90: return .init(x: y, y: source.height - 1 - x); case .degrees180: return .init(x: source.width - 1 - x, y: source.height - 1 - y); case .degrees270: return .init(x: source.width - 1 - y, y: x) }
    }
}

/// Shared display/input geometry. The renderer draws exactly `rect`; input
/// mapping uses the same aspect-fit bounds, so letterbox margins cannot become
/// a different coordinate system.
public struct ScrcpyPresentationGeometry: Equatable, Sendable {
    public let source: CGSize
    public let destination: CGSize
    public init(source: CGSize, destination: CGSize) { self.source = source; self.destination = destination }
    public var scale: CGFloat {
        guard source.width > 0, source.height > 0, destination.width > 0, destination.height > 0 else { return 0 }
        return min(destination.width / source.width, destination.height / source.height)
    }
    public var rect: CGRect {
        guard scale > 0 else { return .zero }
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (destination.width - size.width) / 2, y: (destination.height - size.height) / 2, width: size.width, height: size.height)
    }
    public func map(_ point: CGPoint) -> CGPoint {
        guard scale > 0 else { return .zero }
        return CGPoint(
            x: min(max((point.x - rect.minX) / scale, 0), source.width - 1),
            y: min(max((point.y - rect.minY) / scale, 0), source.height - 1)
        )
    }
}

/// Shared fixture renderer with no endpoint or lifecycle authority. It is
/// usable both by the AppKit view and by an offscreen Metal verification test.
public final class ScrcpyPixelBufferRenderer {
    private let context: CIContext
    public init?(device: MTLDevice) { context = CIContext(mtlDevice: device) }
    public func render(pixelBuffer: CVPixelBuffer?, to texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let canvas = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        let black = CIImage(color: .black).cropped(to: canvas)
        guard let pixelBuffer else { context.render(black, to: texture, commandBuffer: commandBuffer, bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB()); return }
        guard let image = image(from: pixelBuffer) else { context.render(black, to: texture, commandBuffer: commandBuffer, bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB()); return }
        let geometry = ScrcpyPresentationGeometry(source: image.extent.size, destination: canvas.size)
        let rect = geometry.rect
        guard !rect.isEmpty else { context.render(black, to: texture, commandBuffer: commandBuffer, bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB()); return }
        let transform = CGAffineTransform(a: geometry.scale, b: 0, c: 0, d: geometry.scale, tx: rect.minX, ty: rect.minY)
        context.render(image.transformed(by: transform).composited(over: black), to: texture, commandBuffer: commandBuffer, bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
    private func image(from pixelBuffer: CVPixelBuffer) -> CIImage? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let data = Data(bytes: base, count: CVPixelBufferGetBytesPerRow(pixelBuffer) * Int(size.height))
        return CIImage(bitmapData: data, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), size: size, format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}
