//
//  BLEScanner.swift
//  CoreBluetooth central that logs advertised RSSI of nearby peripherals,
//  replacing the Slogger BLE-logging role. Foreground scanning with duplicates
//  allowed gives an RSSI sample per received advertisement.
//
//  iOS caveats vs Android: no raw MAC (peripherals are identified by a per-app
//  UUID), duplicate-allowed scanning only works in the foreground, and sample
//  rate is capped by how often the watch advertises.
//
import Foundation
import CoreBluetooth

final class BLEScanner: NSObject, CBCentralManagerDelegate {
    /// wall time, display name, per-app UUID, RSSI (dBm)
    var onSample: ((Date, String, String, Int) -> Void)?
    /// only log peripherals whose name contains this (case-insensitive); empty = all
    var nameFilter: String = ""
    var onStatus: ((String) -> Void)?

    private var central: CBCentralManager?

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func stop() {
        central?.stopScan()
        central = nil
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            onStatus?("BLE scanning")
            c.scanForPeripherals(withServices: nil,
                                 options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case .poweredOff:      onStatus?("BLE off — enable Bluetooth")
        case .unauthorized:    onStatus?("BLE unauthorized — allow Bluetooth in Settings")
        case .unsupported:     onStatus?("BLE unsupported on this device")
        default:               onStatus?("BLE unavailable")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "?"
        if !nameFilter.isEmpty && !name.lowercased().contains(nameFilter.lowercased()) { return }
        onSample?(Date(), name, peripheral.identifier.uuidString, RSSI.intValue)
    }
}
