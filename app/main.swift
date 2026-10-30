// Rokid Screen: the Mac desktop on the Rokid Max 2 glasses as a screen that
// stays put in the room while you turn your head.
//
// The glasses are an ordinary 1920x1080 display to macOS. The app captures
// that display with ScreenCaptureKit (leaving its own window out), and
// covers it with a window that draws the captured desktop as a flat screen
// in space, turned against the head's rotation from the glasses' IMU.
// Mouse clicks pass through the window to the real desktop underneath, and
// the app draws the pointer on the floating screen itself.
//
// Controls: the menu bar icon; a double tap on the frame holds the screen
// still in view, a triple tap recenters it. With a keyboard on the Mac, ⌃⌥R
// recenter, ⌃⌥= / ⌃⌥- bigger / smaller, ⌃⌥H hold, ⌃⌥Q quit (these don't
// arrive over Screen Sharing).

import AppKit
import Carbon.HIToolbox
import CoreMedia
import Metal
import MetalKit
import ScreenCaptureKit
import simd

// MARK: Settings

struct Placement {
    // Horizontal angle the screen covers
    var widthDeg: Float = 40
    // Where it sits: turned and raised from straight ahead in the IMU's world
    var yaw: Float = 0
    var pitch: Float = 0

    // Distance the screen appears at in 3D (each eye sees it from its own place)
    var distance: Float = 2.0
    // Height over what square pixels would give
    var stretch: Float = 1
    static let ipd: Float = 0.063
    // 2D and 3D keep their own size: the 3D desktop is twice as wide
    var stereo = false
    var key: String { stereo ? "widthDeg3D" : "widthDeg" }

    static func load(stereo: Bool = false) -> Placement {
        var p = Placement()
        p.stereo = stereo
        let d = UserDefaults.standard
        if d.object(forKey: p.key) != nil { p.widthDeg = max(15, min(999, d.float(forKey: p.key))) }
        else if stereo { p.widthDeg = 82 } // 23° tall: between 72° (too short) and 93° (too much turning), Will's pick
        // The curved screen sits further off, like a big screen across a room
        if stereo { p.distance = 3.5 }
        return p
    }

    func save() {
        UserDefaults.standard.set(widthDeg, forKey: key)
    }
}

// Rokid Max 2: 50° diagonal on a 16:9 panel
let diagonalFovDeg: Float = 50

// MARK: Desktop capture

final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    var excludedWindowID: CGWindowID = 0
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "rokid.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var cache: CVMetalTextureCache?
    private(set) var texture: MTLTexture?
    // The last few frames stay alive: the GPU may still be drawing from them
    private var backing: [CVMetalTexture] = []
    var onFirstFrame: (() -> Void)?
    private var gotFirst = false

    init(displayID: CGDirectDisplayID, device: MTLDevice) {
        self.displayID = displayID
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    private var stopped = false

    func start(attempt: Int = 0) {
        guard !stopped else { return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                if let error {
                    print("[capture] unavailable: \(error.localizedDescription)")
                    if attempt == 0 { CGRequestScreenCaptureAccess() }
                    // Try again until Screen Recording is allowed
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start(attempt: attempt + 1) }
                    return
                }
                guard let display = content?.displays.first(where: { $0.displayID == self.displayID }) else {
                    print("[capture] display \(self.displayID) not offered")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start(attempt: attempt + 1) }
                    return
                }
                let own = content?.windows.filter { $0.windowID == self.excludedWindowID } ?? []
                let filter = SCContentFilter(display: display, excludingWindows: own)
                let cfg = SCStreamConfiguration()
                let mode = CGDisplayCopyDisplayMode(self.displayID)
                cfg.width = mode?.pixelWidth ?? 1920
                cfg.height = mode?.pixelHeight ?? 1080
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.colorSpaceName = CGColorSpace.sRGB
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                cfg.queueDepth = 5
                // The app draws the pointer where it belongs on the floating screen
                cfg.showsCursor = false
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                do {
                    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                } catch {
                    print("[capture] could not add output: \(error.localizedDescription)")
                    return
                }
                self.stream = s
                s.startCapture { error in
                    if let error { print("[capture] did not start: \(error.localizedDescription)") }
                    else { print("[capture] capturing display \(self.displayID) at \(cfg.width)x\(cfg.height)") }
                }
            }
        }
    }

    // The window is on screen now: leave it out of the capture, or the app
    // would film its own output
    func excludeOwnWindow(attempt: Int = 0) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self, let stream = self.stream,
                      let display = content?.displays.first(where: { $0.displayID == self.displayID }) else { return }
                let own = content?.windows.filter { $0.windowID == self.excludedWindowID } ?? []
                if own.isEmpty {
                    print("[capture] own window \(self.excludedWindowID) not listed yet")
                    if attempt < 20 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.excludeOwnWindow(attempt: attempt + 1) }
                    }
                    return
                }
                stream.updateContentFilter(SCContentFilter(display: display, excludingWindows: own)) { error in
                    if let error { print("[capture] could not leave own window out: \(error.localizedDescription)") }
                    else { print("[capture] own window left out of the capture") }
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lock.lock()
        pending = pb
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopped else { return }
        print("[capture] stopped: \(error.localizedDescription); restarting")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
    }

    // Newest frame as a texture; the desktop sends frames only when it changes
    func update() {
        lock.lock()
        let pb = pending
        pending = nil
        lock.unlock()
        guard let pb, let cache else { return }
        var tex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &tex) == kCVReturnSuccess,
              let tex, let t = CVMetalTextureGetTexture(tex) else { return }
        texture = t
        backing.append(tex)
        if backing.count > 4 { backing.removeFirst() }
        if !gotFirst {
            gotFirst = true
            print("[capture] first frame \(w)x\(h)")
            DispatchQueue.main.async { self.onFirstFrame?() }
        }
    }

    func stop() {
        stopped = true
        stream?.stopCapture(completionHandler: nil)
        stream = nil
    }
}

// MARK: Rendering

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float3x3 headToScreen; // view rays from head space into the screen's space
    float4 eye;            // xyz: this eye's place in head space (m), w: screen distance (m)
    float2 tanHalf;        // tangent of half the glasses' field of view
    float2 halfSize;       // screen half width and height, at distance 1
    float2 cursorOrigin;   // pointer image's top left, in texture coordinates
    float2 cursorSize;     // its size, in texture coordinates
    float aspect;          // texture width / height
    float2 uvShift;        // this eye's picture moved sideways (spatial media's disparity adjustment)
    float curved;          // 1: a curved screen around you (halfSize.x is then half its angle, radians)
};

struct VOut { float4 pos [[position]]; float2 ndc; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    VOut o;
    o.pos = float4(p, 0, 1);
    o.ndc = p;
    return o;
}

fragment float4 fmain(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                      texture2d<float> tex [[texture(0)]], texture2d<float> pointer [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 ray = u.headToScreen * float3(in.ndc * u.tanHalf, -1.0);
    float3 origin = u.headToScreen * u.eye.xyz;
    float D = u.eye.w;
    float2 uv;
    if (u.curved > 0.5) {
        // Part of a cylinder around you, radius D: from inside, the far
        // crossing of x² + z² = D²
        float a = dot(ray.xz, ray.xz);
        float b = 2.0 * dot(origin.xz, ray.xz);
        float c0 = dot(origin.xz, origin.xz) - D * D;
        float disc = b * b - 4.0 * a * c0;
        if (a < 1e-8 || disc < 0) return float4(0, 0, 0, 1);
        float t = (-b + sqrt(disc)) / (2.0 * a);
        float3 p = origin + t * ray;
        // Across: the angle around you; up: height on the wall (same units, so pixels stay square)
        float phi = atan2(p.x, -p.z);
        uv = float2(phi / (2.0 * u.halfSize.x), -(p.y / D) / (2.0 * u.halfSize.y)) + 0.5;
    } else {
        if (ray.z >= -1e-4) return float4(0, 0, 0, 1);
        float t = (-D - origin.z) / ray.z;
        float2 p = (origin.xy + t * ray.xy) / D;  // on the plane, scaled to distance 1
        uv = float2(p.x / u.halfSize.x, -p.y / u.halfSize.y) * 0.5 + 0.5;
    }
    float2 fw = fwidth(uv);
    float2 edge = smoothstep(float2(0), fw, uv) * smoothstep(float2(0), fw, 1.0 - uv);
    float inside = edge.x * edge.y;
    if (inside <= 0) return float4(0, 0, 0, 1);
    float3 c = tex.sample(s, uv + u.uvShift).rgb;
    // The Mac's own pointer image (premultiplied alpha)
    float2 pc = (uv - u.cursorOrigin) / u.cursorSize;
    if (all(pc >= 0.0) && all(pc <= 1.0)) {
        constexpr sampler ps(filter::linear, address::clamp_to_zero);
        float4 pk = pointer.sample(ps, pc);
        c = c * (1.0 - pk.a) + pk.rgb;
    }
    return float4(c * inside, 1);
}
"""

struct Uniforms {
    var headToScreen: simd_float3x3
    var eye: SIMD4<Float>
    var tanHalf: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var cursorOrigin: SIMD2<Float>
    var cursorSize: SIMD2<Float>
    var aspect: Float
    var uvShift = SIMD2<Float>(0, 0)
    var curved: Float = 0
}

// The pointer macOS currently shows (arrow, I-beam, hand...), as a texture
final class PointerImage {
    let device: MTLDevice
    private(set) var texture: MTLTexture?
    private(set) var hotSpot = CGPoint.zero
    private(set) var size = CGSize(width: 1, height: 1) // points
    private var lastKey = ""
    private var tick = 0

    init(device: MTLDevice) { self.device = device }

    func update() {
        tick += 1
        guard tick % 4 == 0 || texture == nil else { return }
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let img = cursor.image
        let key = "\(ObjectIdentifier(img)) \(cursor.hotSpot) \(img.size)"
        guard key != lastKey else { return }
        lastKey = key
        let scale: CGFloat = 2
        let w = Int(img.size.width * scale), h = Int(img.size.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        guard let t = device.makeTexture(descriptor: td), let data = ctx.data else { return }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        texture = t
        hotSpot = cursor.hotSpot
        size = img.size
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    var capture: DesktopCapture
    let imu: RokidIMU
    var placement = Placement.load()
    lazy var pointer = PointerImage(device: device)
    // A photo or video shown instead of the desktop, with its own placement
    var media: MediaSource?
    var desktopPlacement: Placement?
    // Screen held in view (tracking off)
    var holding = false
    var screenFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    var predictAhead = 0.025
    private var frames = 0
    private var lastReport = CACurrentMediaTimeCompat()
    var onFrame: (() -> Void)?

    init(device: MTLDevice, capture: DesktopCapture, imu: RokidIMU, format: MTLPixelFormat) throws {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.capture = capture
        self.imu = imu
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "vmain")
        pd.fragmentFunction = lib.makeFunction(name: "fmain")
        pd.colorAttachments[0].pixelFormat = format
        pipeline = try device.makeRenderPipelineState(descriptor: pd)
    }

    // Glasses' view angles from the diagonal
    var tanHalf: SIMD2<Float> {
        let t = tan(diagonalFovDeg * .pi / 360)
        let diag = Float((16.0 * 16.0 + 9.0 * 9.0).squareRoot())
        return SIMD2(t * 16 / diag, t * 9 / diag)
    }

    // Widest the screen may be and still fit the glasses' view top to
    // bottom, and across as well unless the desktop itself is wider than
    // the glasses (3D's double-wide desktop, which you look across)
    func maxWidthDeg(aspect: Float, curved: Bool = false) -> Float {
        let t = tanHalf
        // Curved: the arc around you, as long as its height fits the view
        if curved { return 2 * t.y * aspect * 180 / .pi }
        return 2 * atan(min(t.x, t.y * aspect)) * 180 / .pi
    }

    var textureAspect: Float {
        guard let t = capture.texture else { return 16.0 / 9.0 }
        return Float(t.width) / Float(max(t.height, 1))
    }

    func head() -> simd_quatf {
        imu.orientation(ahead: predictAhead)
    }

    // Put the screen where the head points now, kept upright
    func recenter() {
        let f = head().act(SIMD3<Float>(0, 0, -1))
        placement.yaw = atan2(-f.x, -f.z)
        placement.pitch = asin(max(-1, min(1, f.y)))
        print(String(format: "[screen] recentered at yaw %.1f° pitch %.1f°",
                     placement.yaw * 180 / .pi, placement.pitch * 180 / .pi))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        onFrame?()
        capture.update()
        media?.update()
        let showingMedia = media?.left != nil
        guard let tex = showingMedia ? media?.left : capture.texture, let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }

        let screenRot = simd_quatf(angle: placement.yaw, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: placement.pitch, axis: SIMD3(1, 0, 0))
        let headRot = holding ? screenRot : head()
        let headToScreen = simd_float3x3(screenRot.inverse * headRot)
        let aspect = Float(tex.width) / Float(max(tex.height, 1))
        // The 3D desktop (3840x1080) curves around you; its height still fits the view
        let curved = placement.stereo && !showingMedia
        let stretch = curved ? placement.stretch : 1
        placement.widthDeg = min(placement.widthDeg, maxWidthDeg(aspect: aspect / stretch, curved: curved))
        let halfW = curved ? placement.widthDeg * .pi / 360 : tan(placement.widthDeg * .pi / 360)
        let panelAspect = aspect

        // Pointer where macOS has it, hot spot on the spot
        pointer.update()
        let m = NSEvent.mouseLocation
        let fw = max(screenFrame.width, 1), fh = max(screenFrame.height, 1)
        let ox = (m.x - screenFrame.minX - pointer.hotSpot.x) / fw
        let oy = 1 - (m.y - screenFrame.minY) / fh - pointer.hotSpot.y / fh

        var u = Uniforms(headToScreen: headToScreen, eye: SIMD4(0, 0, 0, placement.distance), tanHalf: tanHalf,
                         halfSize: SIMD2(halfW, halfW / panelAspect * stretch),
                         cursorOrigin: showingMedia ? SIMD2(-10, -10) : SIMD2(Float(ox), Float(oy)),
                         cursorSize: SIMD2(Float(pointer.size.width / fw), Float(pointer.size.height / fh)),
                         aspect: aspect)

        u.curved = curved ? 1 : 0

        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].loadAction = .clear
        let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(pointer.texture, index: 1)
        // 3D: the glasses take the left half for the left eye, the right half
        // for the right, each seeing the screen from its own place
        let size = view.drawableSize
        let eyes: [Float] = placement.stereo ? [-Placement.ipd / 2, Placement.ipd / 2] : [0]
        for (i, x) in eyes.enumerated() {
            let w = size.width / Double(eyes.count)
            enc.setViewport(MTLViewport(originX: w * Double(i), originY: 0, width: w, height: size.height, znear: 0, zfar: 1))
            u.eye = SIMD4(x, 0, 0, placement.distance)
            // Spatial media: each eye its own picture, the left one alone in 2D
            var eyeTex = tex
            if showingMedia, let m = media {
                if placement.stereo, i == 1, let r = m.right { eyeTex = r }
                let d = placement.stereo && m.isSpatial ? m.disparityAdjust / 2 : 0
                u.uvShift = SIMD2(i == 0 ? d : -d, 0)
            } else {
                u.uvShift = .zero
            }
            enc.setFragmentTexture(eyeTex, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        frames += 1
        let now = CACurrentMediaTimeCompat()
        if now - lastReport >= 10 {
            print(String(format: "[render] %.1f fps, imu %d samples", Double(frames) / (now - lastReport), imu.samples))
            frames = 0
            lastReport = now
        }
    }
}

// MARK: Hot keys

final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let user, let event else { return OSStatus(eventNotHandledErr) }
            let keys = Unmanaged<HotKeys>.fromOpaque(user).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard let action = keys.actions[id.id] else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async(execute: action)
            return noErr
        }, 1, &spec, me, &handler)
        if status != noErr { print("[hotkey] handler not installed: \(status)") }
    }

    // ⌃⌥ + key
    func add(_ keyCode: Int, _ action: @escaping () -> Void) {
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: OSType(0x524B_4944), id: id), // "RKID"
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { print("[hotkey] ⌃⌥ key \(keyCode) not registered: \(status)") }
        if let ref { refs.append(ref) }
    }
}

// MARK: Pointer
// Private CoreGraphics calls: with "SetsCursorInBackground" an app may hide
// the pointer while another app is in front (as Cursorcerer does)
@_silgen_name("_CGSDefaultConnection") func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32
@_silgen_name("CGCursorIsVisible") func CGCursorIsVisibleCompat() -> Int32

var pointerHides = 0
func hideSystemPointer() {
    let cid = _CGSDefaultConnection()
    _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    // Hides stack up and each needs a show on quit: past a few, give one
    // back first so the count stays small through hours of re-hiding
    if pointerHides >= 8 {
        CGDisplayShowCursor(kCGNullDirectDisplay)
        pointerHides -= 1
    }
    CGDisplayHideCursor(kCGNullDirectDisplay)
    pointerHides += 1
}
func showSystemPointer() {
    for _ in 0..<max(pointerHides, 1) { CGDisplayShowCursor(kCGNullDirectDisplay) }
    pointerHides = 0
}

// MARK: App

// Borderless panels can't take keys unless they say so
final class KeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with e: NSEvent) {
        if onKey?(e) != true { super.keyDown(with: e) }
    }
}

final class App: NSObject, NSApplicationDelegate {
    var panel: NSPanel?
    var view: MTKView?
    var renderer: Renderer?
    var capture: DesktopCapture?
    let imu = RokidIMU()
    var keys: HotKeys!
    var glassesID: CGDirectDisplayID = 0
    var pointerHidden = false

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let screen = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains("rokid") }),
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else {
            print("[app] no Rokid display connected")
            alert("Rokid glasses not found", "Plug the glasses into the Mac and open Rokid Screen again.")
            NSApp.terminate(nil)
            return
        }
        glassesID = id
        print("[app] glasses display \(id) \"\(screen.localizedName)\" \(screen.frame)")
        imu.onTaps = { [weak self] n in
            switch n {
            case 2: self?.toggleHold()
            case 3: self?.renderer?.recenter()
            default: break
            }
        }
        // Plugged back in: once the first readings have levelled the view,
        // put the screen in front of you again
        imu.onConnect = { [weak self] connected in
            guard connected else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self?.renderer?.recenter() }
        }
        imu.start()

        let device = MTLCreateSystemDefaultDevice()!
        self.device = device
        let cap = DesktopCapture(displayID: id, device: device)
        capture = cap

        let panel = KeyPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false, screen: screen)
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = true
        panel.backgroundColor = .black
        // Above menus, the Dock and alerts, which would otherwise sit on the
        // glasses fixed to the view; they're in the capture all the same
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.onKey = { [weak self] e in self?.handleKey(e) ?? false }
        panel.setFrame(screen.frame, display: false)

        let v = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        v.colorPixelFormat = .bgra8Unorm
        v.preferredFramesPerSecond = 60
        v.framebufferOnly = true
        do {
            let r = try Renderer(device: device, capture: cap, imu: imu, format: v.colorPixelFormat)
            r.screenFrame = screen.frame
            r.placement = Placement.load(stereo: screen.frame.width / screen.frame.height > 3)
            r.onFrame = { [weak self] in self?.keepPointerHidden() }
            renderer = r
            v.delegate = r
        } catch {
            print("[app] shader failed: \(error)")
            NSApp.terminate(nil)
            return
        }
        panel.contentView = v
        self.panel = panel
        view = v
        cap.excludedWindowID = CGWindowID(panel.windowNumber)

        startCapture(cap, recenterAfter: 1.6)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.screensChanged() }
        // 3D was on when the app last quit: switch the glasses back to it
        if UserDefaults.standard.bool(forKey: "stereo"), !isStereoDisplay { setGlassesMode(1) }

        makeMenu()
        watchClicks()
        keys = HotKeys()
        keys.add(kVK_ANSI_R) { [weak self] in self?.renderer?.recenter() }
        keys.add(kVK_ANSI_Equal) { [weak self] in self?.resize(1.1) }
        keys.add(kVK_ANSI_Minus) { [weak self] in self?.resize(1 / 1.1) }
        keys.add(kVK_ANSI_H) { [weak self] in self?.toggleHold() }
        keys.add(kVK_ANSI_Q) { NSApp.terminate(nil) }

        signal(SIGUSR1, SIG_IGN)
        let usr = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr.setEventHandler { [weak self] in self?.renderer?.recenter() }
        usr.resume()
        signalSources.append(usr)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }
    var signalSources: [DispatchSourceSignal] = []
    var statusItem: NSStatusItem?
    var device: MTLDevice?

    // Cover the glasses only once the desktop is coming through, so the
    // Screen Recording prompt can be seen and answered
    func startCapture(_ cap: DesktopCapture, recenterAfter delay: Double) {
        cap.onFirstFrame = { [weak self] in
            guard let self, let panel = self.panel else { return }
            panel.orderFrontRegardless()
            cap.excludeOwnWindow()
            if !self.pointerHidden {
                hideSystemPointer()
                self.pointerHidden = true
            }
            // Wait for the first IMU readings before placing the screen
            if delay >= 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.renderer?.recenter() }
            }
            if self.renderer?.media != nil { self.focusPanel() }
        }
        // Capturing needs the window to exist (to leave it out) but not shown
        panel?.orderOut(nil)
        cap.start()
    }

    var glassesScreen: NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == glassesID
        }
    }

    // In 3D the glasses are one 3840x1080 display, half for each eye
    var isStereoDisplay: Bool {
        let b = CGDisplayBounds(glassesID)
        return b.width / max(b.height, 1) > 3
    }

    // The glasses switched between 2D and 3D (or another display change):
    // capture the desktop afresh at its new size
    func screensChanged() {
        // Plugged back in, the glasses may come back as a different display
        if glassesScreen == nil,
           let s = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains("rokid") }),
           let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
            print("[app] glasses are display \(id) now")
            glassesID = id
            renderer?.screenFrame = .zero // capture afresh below
        }
        guard let screen = glassesScreen, let r = renderer, let panel, let view, let device else { return }
        if isStereoDisplay, let mode = CGDisplayCopyDisplayMode(glassesID), mode.width != 3840 { useFullWidthMode(); return }
        guard screen.frame != r.screenFrame || capture?.displayID != glassesID else { return }
        print("[app] glasses display now \(screen.frame)")
        capture?.stop()
        panel.orderOut(nil)
        panel.setFrame(screen.frame, display: false)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        let cap = DesktopCapture(displayID: glassesID, device: device)
        cap.excludedWindowID = CGWindowID(panel.windowNumber)
        capture = cap
        r.capture = cap
        r.screenFrame = screen.frame
        let stereo = screen.frame.width / screen.frame.height > 3
        if r.media != nil {
            r.placement.stereo = stereo
            r.desktopPlacement = Placement.load(stereo: stereo)
            r.desktopPlacement?.yaw = r.placement.yaw
            r.desktopPlacement?.pitch = r.placement.pitch
        } else {
            let yaw = r.placement.yaw, pitch = r.placement.pitch
            r.placement = Placement.load(stereo: stereo)
            r.placement.yaw = yaw
            r.placement.pitch = pitch
        }
        statusItem?.menu?.item(withTitle: "Curved Wide Screen")?.state = r.placement.stereo ? .on : .off
        startCapture(cap, recenterAfter: r.media != nil ? -1 : 0.3)
    }

    // macOS picks a Retina 1920x540 for the 3D display; 3840x1080 at 1x
    // gives each eye the desktop at the glasses' full sharpness
    func useFullWidthMode() {
        let modes = CGDisplayCopyAllDisplayModes(glassesID, nil) as? [CGDisplayMode] ?? []
        guard let m = modes.first(where: { $0.width == 3840 && $0.pixelWidth == 3840 }) else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, glassesID, m, nil)
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        print("[app] 3D desktop 3840x1080: \(err == .success ? "ok" : "error \(err.rawValue)")")
    }

    // 0: 2D, 1: 3D side by side, through the vendor request Monado uses
    func setGlassesMode(_ mode: Int) {
        let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/rokid-mode")
        let p = Process()
        p.executableURL = tool
        p.arguments = ["\(mode)"]
        do { try p.run(); p.waitUntilExit() } catch { print("[app] could not switch the glasses: \(error)") }
        print("[app] glasses set to \(mode == 1 ? "3D" : "2D")")
    }

    // MARK: Photos and videos

    // Finder's Open With
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if renderer == nil {
            // Opened before launch finished: show it once the glasses are set up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.application(application, open: urls) }
            return
        }
        openMedia(url)
    }

    @objc func menuOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .heic, .heif, .image]
        // Always starts in the home folder; the last folder is never remembered
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { openMedia(url) }
    }
    @objc func menuPause() { renderer?.media?.togglePause() }
    @objc func menuClose() { closeMedia() }

    // Switched to 3D only for a spatial photo or video: back to 2D after
    var switchedToStereoForMedia = false

    func openMedia(_ url: URL) {
        guard let r = renderer, let device else { return }
        r.media?.close()
        let m = MediaSource(device: device)
        m.onReady = { [weak self] in
            guard let self, let r = self.renderer else { return }
            if r.desktopPlacement == nil { r.desktopPlacement = r.placement }
            r.media = m
            r.placement.widthDeg = 999 // as big as fits whole
            r.recenter()
            // 3D for spatial media; back to 2D afterwards unless 3D is the user's choice
            if m.isSpatial, !self.isStereoDisplay, !UserDefaults.standard.bool(forKey: "stereo") {
                self.switchedToStereoForMedia = true
                self.setGlassesMode(1)
            }
            self.focusPanel()
        }
        m.open(url)
    }

    func closeMedia() {
        guard let r = renderer, let m = r.media else { return }
        m.close()
        r.media = nil
        if let d = r.desktopPlacement { r.placement = d }
        r.desktopPlacement = nil
        panel?.resignKey()
        // Keys go back to the app you were using
        NSApp.deactivate()
        if switchedToStereoForMedia {
            switchedToStereoForMedia = false
            setGlassesMode(0)
        }
        print("[media] closed")
    }

    // Keys go to the glasses' window while a photo or video is up
    func focusPanel() {
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKey()
    }

    // Esc closes, Space pauses, arrows skip 10 s
    func handleKey(_ e: NSEvent) -> Bool {
        guard let m = renderer?.media else { return false }
        switch Int(e.keyCode) {
        case kVK_Escape: closeMedia()
        case kVK_Space: m.togglePause()
        case kVK_LeftArrow: m.seek(by: -10)
        case kVK_RightArrow: m.seek(by: 10)
        default: return false
        }
        return true
    }

    @objc func menu3D() {
        let on = !isStereoDisplay
        UserDefaults.standard.set(on, forKey: "stereo")
        setGlassesMode(on ? 1 : 0)
    }

    // Menu bar icon: the same actions as the keys, for when the keys can't
    // reach the app (Screen Sharing, no keyboard on the Mac)
    func makeMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "Rokid Screen")
        let menu = NSMenu()
        func add(_ title: String, _ key: String, _ action: Selector) {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.keyEquivalentModifierMask = [.control, .option]
            mi.target = self
            menu.addItem(mi)
        }
        add("Recenter", "r", #selector(menuRecenter))
        add("Bigger", "=", #selector(menuBigger))
        add("Smaller", "-", #selector(menuSmaller))
        add("Hold Still in View", "h", #selector(menuHold))
        add("Curved Wide Screen", "3", #selector(menu3D))
        menu.item(withTitle: "Curved Wide Screen")?.state = isStereoDisplay ? .on : .off
        menu.addItem(.separator())
        add("Open Photo or Video…", "o", #selector(menuOpen))
        add("Play/Pause", "p", #selector(menuPause))
        add("Close Photo or Video", "w", #selector(menuClose))
        menu.addItem(.separator())
        add("Quit Rokid Screen", "q", #selector(menuQuit))
        item.menu = menu
        statusItem = item
    }
    @objc func menuRecenter() { renderer?.recenter() }
    @objc func menuBigger() { resize(1.1) }
    @objc func menuSmaller() { resize(1 / 1.1) }
    @objc func menuHold() { toggleHold() }
    @objc func menuQuit() { NSApp.terminate(nil) }

    func toggleHold() {
        guard let r = renderer else { return }
        r.holding.toggle()
        if !r.holding { r.recenter() }
        statusItem?.menu?.item(at: 3)?.state = r.holding ? .on : .off
        print("[screen] \(r.holding ? "held in view" : "tracking again")")
    }

    func resize(_ factor: Float) {
        guard let r = renderer else { return }
        let curved = r.placement.stereo && r.media == nil
        let maxW = r.maxWidthDeg(aspect: r.textureAspect / (curved ? r.placement.stretch : 1), curved: curved)
        r.placement.widthDeg = max(15, min(maxW, r.placement.widthDeg * factor))
        if r.media == nil { r.placement.save() }
        print(String(format: "[screen] width %.0f°", r.placement.widthDeg))
    }

    // The Dock, menus or another app can bring the pointer back
    // A context menu (right-click) shows the pointer again while
    // CGCursorIsVisible still says hidden, so for a while after any click
    // hide it again regardless, a few times a second
    var forceHideUntil: Double = 0
    var lastForcedHide: Double = 0
    var mouseMonitor: Any?

    func keepPointerHidden() {
        guard pointerHidden else { return }
        let now = CACurrentMediaTimeCompat()
        if CGCursorIsVisibleCompat() != 0 {
            hideSystemPointer()
        } else if now < forceHideUntil || pointerNearEdge(), now - lastForcedHide > 0.15 {
            lastForcedHide = now
            hideSystemPointer()
        }
    }

    // The Dock, the menu bar and hot corners bring the pointer back near the
    // display's edges, again without CGCursorIsVisible noticing
    func pointerNearEdge() -> Bool {
        guard let loc = CGEvent(source: nil)?.location else { return false }
        let b = CGDisplayBounds(glassesID)
        return loc.y > b.maxY - 110 || loc.y < b.minY + 40 || loc.x < b.minX + 110 || loc.x > b.maxX - 110
    }

    func watchClicks() {
        // Mouse events from other apps reach a global monitor without Accessibility
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        ]) { [weak self] _ in
            self?.forceHideUntil = CACurrentMediaTimeCompat() + 2
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        capture?.stop()
        // Without the app a 3D desktop is cut in half between the eyes
        if isStereoDisplay { setGlassesMode(0) }
        if pointerHidden { showSystemPointer() }
        print("[app] quit")
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// Log to a file when started from Finder
if isatty(STDOUT_FILENO) == 0 {
    let path = NSHomeDirectory() + "/Library/Logs/RokidScreen.log"
    freopen(path, "w", stdout)
    freopen(path, "a", stderr)
}
setvbuf(stdout, nil, _IOLBF, 0)

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
