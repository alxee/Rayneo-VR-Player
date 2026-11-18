// decode-test — standalone AVFoundation decode probe (synchronous runloop).
//
// Usage: decode-test [path]
//   without path: generates a small test MP4 in /tmp and probes it
//   with path:    probes that file directly

import AVFoundation
import CoreVideo
import CoreMedia

func log(_ s: String) { print(s); fflush(stdout) }

func fourCC(_ code: OSType) -> String {
    let b = [UInt8(truncatingIfNeeded: code >> 24), UInt8(truncatingIfNeeded: code >> 16),
             UInt8(truncatingIfNeeded: code >> 8), UInt8(truncatingIfNeeded: code)]
    return String(bytes: b, encoding: .ascii) ?? "?"
}

let path: String
if CommandLine.arguments.count > 1 {
    path = CommandLine.arguments[1]
    log("probing \(path)")
} else {
    path = "/tmp/rayneo-decode-test.mp4"
    log("generating test video \(path)")
    do { try generateTestVideo(path: path) } catch { log("generate failed: \(error)"); exit(1) }
}

let asset = AVURLAsset(url: URL(fileURLWithPath: path))
if let track = asset.tracks(withMediaType: .video).first {
    let size = track.naturalSize
    let descs = (track.formatDescriptions as? [CMFormatDescription]) ?? []
    let codec = descs.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
    log("video: \(Int(abs(size.width)))x\(Int(abs(size.height))) codec=\(codec) fps=\(track.nominalFrameRate) audio=\(asset.tracks(withMediaType: .audio).count)")
} else {
    log("no video track found by AVAsset")
}

let player = AVPlayer()
let item = AVPlayerItem(url: URL(fileURLWithPath: path))
let yuv = AVPlayerItemVideoOutput(pixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String:
        NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
])
let bgra = AVPlayerItemVideoOutput(pixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String:
        NSNumber(value: kCVPixelFormatType_32BGRA),
])
item.add(yuv)
item.add(bgra)
player.replaceCurrentItem(with: item)
player.play()

var gotAny = false
var tick = 0
let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
    tick += 1
    let now = player.currentTime()
    let status = item.status == .readyToPlay ? "ready" :
        item.status == .failed ? "FAILED: \(item.error?.localizedDescription ?? "?")" : "loading"
    let yuvPB = yuv.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil)
    let bgraPB = bgra.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil)
    var desc = ""
    if let p = yuvPB {
        desc = "yuv=\(CVPixelBufferGetWidth(p))x\(CVPixelBufferGetHeight(p))"
        gotAny = true
    } else {
        desc = "yuv=nil(new=\(yuv.hasNewPixelBuffer(forItemTime: now)))"
    }
    if let p = bgraPB {
        desc += " bgra=\(CVPixelBufferGetWidth(p))x\(CVPixelBufferGetHeight(p))"
        gotAny = true
    } else {
        desc += " bgra=nil"
    }
    log("[\(tick)] t=\(String(format: "%.2f", now.seconds)) rate=\(player.rate) status=\(status) pres=\(item.presentationSize) \(desc)")
    if tick >= 12 {
        t.invalidate()
        player.pause()
        log(gotAny ? "RESULT: frames delivered" : "RESULT: NO frames")
        testAssetReader(path: path)
        exit(gotAny ? 0 : 1)
    }
}
RunLoop.main.add(timer, forMode: .default)
RunLoop.main.run()

// MARK: - AVAssetReader probe (bypasses AVPlayer entirely)

/// Reads ~10 sample buffers from the video track via AVAssetReader and
/// reports whether the demuxer/decoder chain can deliver frames at all.
func testAssetReader(path: String) {
    log("--- AVAssetReader test ---")
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .video).first else {
        log("reader: no video track")
        return
    }

    // YUV 4:2:0 (the format the app wants), then BGRA as fallback.
    for (name, settings) in [
        ("yuv420", [kCVPixelBufferPixelFormatTypeKey as String:
                        NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]),
        ("bgra", [kCVPixelBufferPixelFormatTypeKey as String:
                      NSNumber(value: kCVPixelFormatType_32BGRA)]),
    ] {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            log("reader[\(name)] create FAILED: \(error.localizedDescription)")
            return
        }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        if !reader.canAdd(out) {
            log("reader[\(name)] canAdd FAILED")
            continue
        }
        reader.add(out)
        reader.startReading()
        var n = 0
        var dims = ""
        while n < 10, let sb = out.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sb) {
                dims = "\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))"
            }
            n += 1
        }
        if n > 0 {
            log("reader[\(name)] DELIVERED \(n) samples \(dims)")
        } else {
            let e = reader.error
            log("reader[\(name)] NO samples status=\(reader.status.rawValue) err=\(e.map { "\($0)" } ?? "none")")
        }
        reader.cancelReading()
    }
}

// MARK: - test video generation

func generateTestVideo(path: String) throws {
    try? FileManager.default.removeItem(atPath: path)
    let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: 1920,
        AVVideoHeightKey: 1080,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 1920,
        kCVPixelBufferHeightKey as String: 1080,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let group = DispatchGroup()
    group.enter()
    var frame = 0
    input.requestMediaDataWhenReady(on: DispatchQueue(label: "gen")) {
        while input.isReadyForMoreMediaData, frame < 90 {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            if let pb {
                CVPixelBufferLockBaseAddress(pb, [])
                if let base = CVPixelBufferGetBaseAddress(pb) {
                    let stride = CVPixelBufferGetBytesPerRow(pb)
                    let h = CVPixelBufferGetHeight(pb)
                    for y in 0..<h {
                        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                        for x in 0..<CVPixelBufferGetWidth(pb) {
                            row[x * 4 + 0] = UInt8(truncatingIfNeeded: y * 255 / h)
                            row[x * 4 + 1] = UInt8(truncatingIfNeeded: x * 255 / 1920)
                            row[x * 4 + 2] = UInt8(truncatingIfNeeded: frame * 3)
                            row[x * 4 + 3] = 255
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(pb, [])
                adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
            }
            frame += 1
        }
        if frame >= 90 {
            input.markAsFinished()
            group.leave()
        }
    }
    group.wait()
    writer.finishWriting {}
    while writer.status == .writing { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
}
