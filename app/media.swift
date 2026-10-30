// Spatial photos and videos, each eye's picture to its own eye.
//
// A spatial photo is a HEIC whose stereo pair group names a left and a
// right image. A spatial video is MV-HEVC: AVPlayerVideoOutput hands over
// both eye views of each frame, tagged left and right (one tag collection
// asking for both; separate left and right collections vend nothing on
// macOS 27, as the PS VR2 player found). Anything else plays flat, the
// same picture to both eyes.
//
// File names and folders are never logged or remembered.

import AVFoundation
import AppKit
import CoreMedia
import ImageIO
import Metal
import MetalKit

final class MediaSource {
    let device: MTLDevice
    private(set) var left: MTLTexture?
    private(set) var right: MTLTexture?
    private(set) var isSpatial = false
    private(set) var isVideo = false
    // Fraction of one eye's width; positive pushes the picture back
    private(set) var disparityAdjust: Float = 0
    var onReady: (() -> Void)?

    private var player: AVPlayer?
    private var flatOutput: AVPlayerItemVideoOutput?
    private var stereoOutput: AnyObject? // AVPlayerVideoOutput
    private var cache: CVMetalTextureCache?
    private var backing: [CVMetalTexture] = []
    private var lastTime = CMTime.invalid
    private var loggedFrame = false
    private var loopObserver: NSObjectProtocol?

    static let bgra: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    var aspect: Float {
        guard let t = left else { return 16.0 / 9.0 }
        return Float(t.width) / Float(max(t.height, 1))
    }

    var isPlaying: Bool { (player?.rate ?? 0) != 0 }

    static func isVideoFile(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return type?.conforms(to: .movie) ?? false
    }

    func open(_ url: URL) {
        if Self.isVideoFile(url) { openVideo(url) } else { openPhoto(url) }
    }

    // MARK: Photos

    private func openPhoto(_ url: URL) {
        isVideo = false
        // Decoding a 24-48 MP HEIC takes a moment: off the main thread
        DispatchQueue.global(qos: .userInitiated).async { [device] in
            let loaded = Self.loadPhoto(url, device: device)
            DispatchQueue.main.async {
                guard let loaded else { print("[media] photo could not be read"); return }
                self.left = loaded.0
                self.right = loaded.1
                self.isSpatial = loaded.1 != nil
                self.disparityAdjust = loaded.2
                print("[media] photo \(loaded.0.width)x\(loaded.0.height), \(self.isSpatial ? "spatial" : "2D")")
                self.onReady?()
            }
        }
    }

    private static func loadPhoto(_ url: URL, device: MTLDevice) -> (MTLTexture, MTLTexture?, Float)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var leftIndex = CGImageSourceGetPrimaryImageIndex(src)
        var rightIndex: Int?
        var disparity: NSNumber?
        let isPair = { (g: [String: Any]) in
            (g[kCGImagePropertyGroupType as String] as? String) == (kCGImagePropertyGroupTypeStereoPair as String)
        }
        let fileProps = CGImageSourceCopyProperties(src, nil) as? [String: Any]
        for g in fileProps?[kCGImagePropertyGroups as String] as? [[String: Any]] ?? [] where isPair(g) {
            if let l = g[kCGImagePropertyGroupImageIndexLeft as String] as? Int,
               let r = g[kCGImagePropertyGroupImageIndexRight as String] as? Int {
                leftIndex = l
                rightIndex = r
            }
            disparity = disparity ?? g[kCGImagePropertyGroupImageDisparityAdjustment as String] as? NSNumber
        }
        for i in 0..<CGImageSourceGetCount(src) {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any]
            for g in props?[kCGImagePropertyGroups as String] as? [[String: Any]] ?? [] where isPair(g) {
                if rightIndex == nil {
                    if (g[kCGImagePropertyGroupImageIsLeftImage as String] as? Bool) == true { leftIndex = i }
                    if (g[kCGImagePropertyGroupImageIsRightImage as String] as? Bool) == true { rightIndex = i }
                }
                disparity = disparity ?? g[kCGImagePropertyGroupImageDisparityAdjustment as String] as? NSNumber
            }
        }
        if rightIndex == leftIndex { rightIndex = nil }
        let loader = MTKTextureLoader(device: device)
        func texture(_ index: Int) -> MTLTexture? {
            // Through the thumbnail call at full size: it applies the EXIF orientation
            let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any]
            let longSide = max(props?[kCGImagePropertyPixelWidth as String] as? Int ?? 0,
                               props?[kCGImagePropertyPixelHeight as String] as? Int ?? 0)
            guard longSide > 0, let image = CGImageSourceCreateThumbnailAtIndex(src, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(longSide, 8192),
            ] as CFDictionary) else { return nil }
            return try? loader.newTexture(cgImage: image, options: [
                .SRGB: false,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
            ])
        }
        guard let l = texture(leftIndex) else { return nil }
        let r = rightIndex.flatMap(texture)
        let d = Float(max(-10000, min(10000, disparity?.doubleValue ?? 0)) / 10000)
        return (l, r, d)
    }

    // MARK: Videos

    private func openVideo(_ url: URL) {
        isVideo = true
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        Task { @MainActor in
            let asset = item.asset
            let track = try? await asset.loadTracks(withMediaType: .video).first
            let traits = (try? await track?.load(.mediaCharacteristics)) ?? []
            let formats = (try? await track?.load(.formatDescriptions)) ?? []
            isSpatial = traits.contains(.containsStereoMultiviewVideo)
            if let desc = formats.first, let exts = CMFormatDescriptionGetExtensions(desc) as? [String: Any],
               let adj = exts["\(kCMFormatDescriptionExtension_HorizontalDisparityAdjustment)"] as? NSNumber {
                disparityAdjust = Float(max(-10000, min(10000, adj.doubleValue)) / 10000)
            }
            if isSpatial, #available(macOS 14.2, *) {
                let both: [CMTag] = [CMTag.stereoView([.leftEye, .rightEye])]
                let leftOnly: [CMTag] = [CMTag.stereoView(.leftEye)]
                let spec = AVVideoOutputSpecification(tagCollections: [both, leftOnly])
                spec.defaultPixelBufferAttributes = Self.bgra
                let out = AVPlayerVideoOutput(specification: spec)
                p.videoOutput = out
                stereoOutput = out
            } else {
                let out = AVPlayerItemVideoOutput(pixelBufferAttributes: Self.bgra)
                item.add(out)
                flatOutput = out
            }
            print("[media] video, \(isSpatial ? "spatial" : "2D")")
            // Loop at the end
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak p] _ in
                p?.seek(to: .zero)
                p?.play()
            }
            p.play()
            onReady?()
        }
    }

    // Newest frame for each eye; called every display frame
    func update() {
        guard isVideo, let cache else { return }
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        if #available(macOS 14.2, *), let out = stereoOutput as? AVPlayerVideoOutput {
            guard let result = out.taggedBuffers(forHostTime: host),
                  result.presentationTime != lastTime else { return }
            lastTime = result.presentationTime
            var l: CVPixelBuffer?, r: CVPixelBuffer?
            for tagged in result.taggedBufferGroup {
                guard case .pixelBuffer(let pb) = tagged.buffer else { continue }
                let eye = tagged.tags.lazy.compactMap {
                    $0.value(onlyIfMatching: CMTypedTag<CMStereoViewComponents>.Category.stereoView)
                }.first
                if eye?.contains(.rightEye) == true { r = pb } else if eye?.contains(.leftEye) == true { l = pb }
            }
            guard let l else { return }
            retire()
            left = texture(l, cache)
            right = r.flatMap { texture($0, cache) }
            if !loggedFrame {
                loggedFrame = true
                print("[media] first frame \(CVPixelBufferGetWidth(l))x\(CVPixelBufferGetHeight(l)) per eye, right eye \(r != nil ? "decoded" : "missing")")
            }
        } else if let out = flatOutput {
            let t = out.itemTime(forHostTime: CACurrentMediaTime())
            guard out.hasNewPixelBuffer(forItemTime: t),
                  let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
            retire()
            left = texture(pb, cache)
            right = nil
        }
    }

    // Frames the GPU may still be drawing from stay alive a little longer
    private var retired: [[CVMetalTexture]] = []
    private func retire() {
        retired.append(backing)
        if retired.count > 3 { retired.removeFirst() }
        backing = []
    }

    private func texture(_ pb: CVPixelBuffer, _ cache: CVMetalTextureCache) -> MTLTexture? {
        var tex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &tex) == kCVReturnSuccess,
              let tex else { return nil }
        backing.append(tex)
        return CVMetalTextureGetTexture(tex)
    }

    func togglePause() {
        guard let p = player else { return }
        if p.rate == 0 { p.play() } else { p.pause() }
    }

    func seek(by seconds: Double) {
        guard let p = player else { return }
        let t = CMTimeAdd(p.currentTime(), CMTime(seconds: seconds, preferredTimescale: 600))
        p.seek(to: CMTimeMaximum(t, .zero))
    }

    func close() {
        player?.pause()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        player = nil
        left = nil
        right = nil
        backing = []
    }
}
