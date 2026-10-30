// Head orientation from the Rokid glasses' motion sensor.
//
// The glasses send 64-byte reports (id 17) on their vendor HID interface,
// about 430 per second: device time in ns, accelerometer (m/s²), gyro
// (rad/s) and magnetometer, in OpenXR axes (x right, y up, z back), as
// Monado's Rokid driver reads them. IOHIDManager hands them over without
// root or a driver.

import Foundation
import IOKit.hid
import simd

final class RokidIMU {
    static let vendorID = 0x04d2

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    private let lock = NSLock()
    private let thread = DispatchQueue(label: "rokid.imu", qos: .userInteractive)

    // Fusion state (IMU thread)
    private var q = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) // body to world
    private var lastDeviceTime: UInt64 = 0
    private var started: Double = 0
    private var bias = SIMD3<Float>(repeating: 0)
    private var stillSince: Double = 0
    private var lastGyro = SIMD3<Float>(repeating: 0)
    private(set) var samples = 0

    // Published to the render thread
    private var shared = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var sharedGyro = SIMD3<Float>(repeating: 0)
    private var sharedTime: Double = 0

    var onConnect: ((Bool) -> Void)?

    func start() {
        thread.async { self.open() }
    }

    private func open() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDPrimaryUsagePageKey: 0xff00,
        ] as CFDictionary)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            let imu = Unmanaged<RokidIMU>.fromOpaque(ctx!).takeUnretainedValue()
            imu.attach(dev)
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
            let imu = Unmanaged<RokidIMU>.fromOpaque(ctx!).takeUnretainedValue()
            if imu.device == dev {
                imu.device = nil
                print("[imu] glasses unplugged")
                DispatchQueue.main.async { imu.onConnect?(false) }
            }
        }, me)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess { print(String(format: "[imu] could not open HID manager: 0x%x", r)) }
        manager = m
        CFRunLoopRun()
    }

    private func attach(_ dev: IOHIDDevice) {
        device = dev
        let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
        print("[imu] reading \(product)")
        started = CACurrentMediaTimeCompat()
        lastDeviceTime = 0
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, reportBuffer, 256, { ctx, _, _, _, id, report, len in
            let imu = Unmanaged<RokidIMU>.fromOpaque(ctx!).takeUnretainedValue()
            imu.handle(id: id, report: report, length: len)
        }, me)
        DispatchQueue.main.async { self.onConnect?(true) }
    }

    private func handle(id: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length >= 49, report[0] == 17 else { return }
        let raw = UnsafeRawPointer(report)
        let t = raw.loadUnaligned(fromByteOffset: 1, as: UInt64.self)
        func vec(_ at: Int) -> SIMD3<Float> {
            SIMD3(raw.loadUnaligned(fromByteOffset: at, as: Float.self),
                  raw.loadUnaligned(fromByteOffset: at + 4, as: Float.self),
                  raw.loadUnaligned(fromByteOffset: at + 8, as: Float.self))
        }
        let accel = vec(9)
        let gyro = vec(21)
        var dt: Float = 0
        if lastDeviceTime != 0, t > lastDeviceTime {
            dt = min(Float(t - lastDeviceTime) * 1e-9, 0.02)
        }
        lastDeviceTime = t
        update(accel: accel, gyro: gyro, dt: dt)
        // Mac time, not the glasses' clock: that restarts from zero when they reconnect
        detectTaps(accel: accel, gyro: gyro, t: CACurrentMediaTimeCompat())
    }

    // MARK: Taps on the frame
    // A tap is a sharp jolt: the accelerometer jumps away from its smoothed
    // value for a few milliseconds. Head turns and nods change it slowly,
    // so they stay under the threshold. Taps close together make a group;
    // the group's count goes to onTaps once no more follow.

    var onTaps: ((Int) -> Void)?
    var tapThreshold: Float = 12      // m/s² above the smoothed reading (taps 25-75, nods under 6)
    private var smoothAccel = SIMD3<Float>(0, 9.81, 0)
    private var tapPeak: Float = 0
    private var tapPeakTime: Double = 0
    private var lastTapTime: Double = 0
    private var tapCount = 0
    private var groupTimer: DispatchWorkItem?

    // A tap's jolt arrives within a sample or two; shaking the head builds
    // it up over many, so the change from one reading to the next tells them apart
    var tapJerkThreshold: Float = 18  // m/s² between consecutive readings (taps 23-51, shakes under 15)
    private var prevAccel = SIMD3<Float>(0, 9.81, 0)
    private var jerkPeak: Float = 0
    private var gyroPeak: Float = 0

    private func detectTaps(accel: SIMD3<Float>, gyro: SIMD3<Float>, t: Double) {
        let jerk = simd_length(accel - prevAccel)
        prevAccel = accel
        let jolt = simd_length(accel - smoothAccel)
        // ~30 ms smoothing at 430 Hz
        smoothAccel += (accel - smoothAccel) * 0.08
        // Track the peak of each spike, judged once it has passed
        if jolt > 2.5 {
            if jolt > tapPeak { tapPeak = jolt; tapPeakTime = t }
            jerkPeak = max(jerkPeak, jerk)
            gyroPeak = max(gyroPeak, simd_length(gyro))
            return
        }
        guard tapPeak > 0 else { return }
        let peak = tapPeak, when = tapPeakTime, sharp = jerkPeak, spin = gyroPeak
        tapPeak = 0; jerkPeak = 0; gyroPeak = 0
        let isTap = peak >= tapThreshold && sharp >= tapJerkThreshold && when - lastTapTime > 0.09
        guard isTap else { return }
        print(String(format: "[tap] jolt %.1f m/s², sharpness %.1f, turn %.1f rad/s", peak, sharp, spin))
        lastTapTime = when
        // Counted on the main queue: this thread is busy in its run loop
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tapCount += 1
            self.groupTimer?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let n = self.tapCount
                self.tapCount = 0
                print("[tap] \(n) tap(s)")
                self.onTaps?(n)
            }
            self.groupTimer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
        }
    }

    // Gyro integration, with gravity pulling tilt back (Mahony style) and the
    // gyro's offset learnt while the head is still. Yaw has nothing to pull
    // it back, so it drifts slowly; recentering (triple tap) resets it.
    private func update(accel: SIMD3<Float>, gyro: SIMD3<Float>, dt: Float) {
        let now = CACurrentMediaTimeCompat()
        samples += 1
        var w = gyro - bias
        let g = simd_length(accel)
        if g > 7.8, g < 11.8 {
            let measuredUp = accel / g
            let predictedUp = q.inverse.act(SIMD3<Float>(0, 1, 0))
            // Fast at first, so the view starts level
            let kp: Float = now - started < 1.5 ? 8 : 0.6
            w += kp * simd_cross(measuredUp, predictedUp)
        }
        // Gyro offset: when it reads barely any rotation for a second, nudge
        // the offset toward what it reads
        if simd_length(gyro - bias) < 0.03, abs(g - 9.81) < 0.4 {
            if stillSince == 0 { stillSince = now }
            if now - stillSince > 1 { bias += (gyro - bias) * 0.002 }
        } else {
            stillSince = 0
        }
        if dt > 0 {
            let angle = simd_length(w) * dt
            if angle > 1e-9 {
                q = simd_normalize(q * simd_quatf(angle: angle, axis: simd_normalize(w)))
            }
        }
        lastGyro = gyro - bias
        lock.lock()
        shared = q
        sharedGyro = lastGyro
        sharedTime = now
        lock.unlock()
    }

    // Orientation predicted `ahead` seconds on from the newest reading, to
    // hide the time until the frame is lit
    func orientation(ahead: Double) -> simd_quatf {
        lock.lock()
        let q0 = shared, w = sharedGyro, t = sharedTime
        lock.unlock()
        let dt = Float(min(max(CACurrentMediaTimeCompat() - t + ahead, 0), 0.08))
        let angle = simd_length(w) * dt
        guard angle > 1e-6 else { return q0 }
        return simd_normalize(q0 * simd_quatf(angle: angle, axis: simd_normalize(w)))
    }
}

func CACurrentMediaTimeCompat() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
}
