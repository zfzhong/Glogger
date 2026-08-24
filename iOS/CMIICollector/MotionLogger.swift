//
//  MotionLogger.swift
//  Tablet-side inertial logging: accelerometer, gyroscope, magnetometer.
//
//  The key property: CMLogItem.timestamp and UITouch.timestamp are both seconds
//  since boot from the same monotonic clock, so tablet IMU aligns to touches and
//  trials with NO clock offset — unlike anything involving the watch. Both are
//  written per sample (`kernel_ts`) alongside wall time.
//
//  Raw sensors are logged, not fused deviceMotion: accel therefore includes
//  gravity, which is what the watch-side pipeline also records.
//
import Foundation
import CoreMotion

final class MotionLogger {
    /// (kind, wallMs, kernelTs, x, y, z) — kind is "accel" | "gyro" | "mag".
    var onSample: ((String, Int, Double, Double, Double, Double) -> Void)?
    var onStatus: ((String) -> Void)?

    /// 100 Hz: the practical ceiling for raw iPad sensors, and double the watch's
    /// 50 Hz accel so the tablet is never the limiting side of an alignment.
    var hz: Double = 100

    private let mm = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "cmii.motion"
        q.maxConcurrentOperationCount = 1      // serial: keeps sample order intact
        q.qualityOfService = .userInitiated
        return q
    }()

    private(set) var nSamples = 0

    func start() {
        let dt = 1.0 / hz
        var available: [String] = []

        if mm.isAccelerometerAvailable {
            mm.accelerometerUpdateInterval = dt
            mm.startAccelerometerUpdates(to: queue) { [weak self] d, _ in
                guard let d else { return }
                self?.emit("accel", d.timestamp,
                           d.acceleration.x, d.acceleration.y, d.acceleration.z)
            }
            available.append("accel")
        }
        if mm.isGyroAvailable {
            mm.gyroUpdateInterval = dt
            mm.startGyroUpdates(to: queue) { [weak self] d, _ in
                guard let d else { return }
                self?.emit("gyro", d.timestamp,
                           d.rotationRate.x, d.rotationRate.y, d.rotationRate.z)
            }
            available.append("gyro")
        }
        if mm.isMagnetometerAvailable {
            mm.magnetometerUpdateInterval = dt
            mm.startMagnetometerUpdates(to: queue) { [weak self] d, _ in
                guard let d else { return }
                self?.emit("mag", d.timestamp,
                           d.magneticField.x, d.magneticField.y, d.magneticField.z)
            }
            available.append("mag")
        }

        onStatus?(available.isEmpty
                  ? "no inertial sensors available"
                  : "IMU \(Int(hz)) Hz: " + available.joined(separator: ", "))
    }

    func stop() {
        mm.stopAccelerometerUpdates()
        mm.stopGyroUpdates()
        mm.stopMagnetometerUpdates()
    }

    private func emit(_ kind: String, _ kts: TimeInterval,
                      _ x: Double, _ y: Double, _ z: Double) {
        nSamples += 1                       // serial queue, so no lock needed
        onSample?(kind, Int(Date().timeIntervalSince1970 * 1000), kts, x, y, z)
    }
}
