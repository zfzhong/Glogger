//
//  BLEAdvertiser.swift
//  Makes the tablet a BLE beacon so the watch can scan it and log RSSI on the
//  watch's own clock — the architecture HANDOFF §4 settled on (IMU and RSSI
//  sharing one clock), without needing an external beacon for foreground studies.
//
//  FOREGROUND ONLY, deliberately. iOS does allow background advertising with the
//  bluetooth-peripheral background mode, but in background the local name is
//  dropped and the service UUIDs move into Apple's proprietary "overflow" area,
//  which only another iOS device scanning for that exact UUID can read. Wear OS
//  cannot see it at all — and it fails silently, which is worse than not working.
//  Natural-use (backgrounded) sessions are the external beacon's job.
//
//  Not settable on iOS: advertising interval and Tx power. The interval decides
//  the watch's RSSI sample rate, so it must be MEASURED, not assumed — see
//  tools/ble_rate_probe.swift.
//
import Foundation
import CoreBluetooth

final class BLEAdvertiser: NSObject, CBPeripheralManagerDelegate {
    /// Kept for a future custom scanner, but NOT advertised — see start() below.
    /// Note for any scanner: never key on the address. iOS rotates the peripheral
    /// address roughly every 15 min and never exposes a MAC, so Slogger's logged
    /// `device.address` column will change mid-session for this advertiser.
    static let serviceUUID = CBUUID(string: "7E5C0001-9B4D-4F1A-A6E2-3C8D5F2A1B90")

    var localName = "CMII-Pad"
    var onStatus: ((String) -> Void)?
    private(set) var isAdvertising = false

    private var pm: CBPeripheralManager?

    func start() {
        guard pm == nil else { return }
        pm = CBPeripheralManager(delegate: self, queue: nil)
    }

    func stop() {
        pm?.stopAdvertising()
        pm = nil
        isAdvertising = false
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        switch p.state {
        case .poweredOn:
            // NAME ONLY - deliberately no service UUID. Slogger filters with
            // ScanFilter.Builder().setDeviceName(name) (sloggerlib/BLEScanner.kt),
            // an EXACT match against the Complete Local Name. A 128-bit service
            // UUID costs 18 of the 31 advertisement bytes and can push the name
            // into the scan response, where the filter may never see it. The UUID
            // buys nothing here because nothing filters on it.
            p.startAdvertising([CBAdvertisementDataLocalNameKey: localName])
        case .poweredOff:   onStatus?("advertise: Bluetooth off")
        case .unauthorized: onStatus?("advertise: Bluetooth not permitted")
        case .unsupported:  onStatus?("advertise: unsupported on this device")
        default:            onStatus?("advertise: unavailable")
        }
    }

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        if let error {
            isAdvertising = false
            onStatus?("advertise failed: \(error.localizedDescription)")
        } else {
            isAdvertising = true
            onStatus?("advertising as \(localName)")
        }
    }
}
