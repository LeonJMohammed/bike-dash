import BikeDashCore
import CoreBluetooth
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.jlmoh.bikedash", category: "heart-rate")

/// Reads the heart rate the Forerunner 165 broadcasts over Bluetooth (the
/// standard Heart Rate service, 0x180D) and keeps reconnecting to that watch.
@MainActor
@Observable
final class HeartRateService: NSObject {
    enum State: Equatable {
        case starting, bluetoothOff, notAllowed, unsupported, searching, waiting, connected
    }

    /// A reading older than this shows as "--".
    static let staleAfter: TimeInterval = 5

    private(set) var state: State = .starting
    private(set) var deviceName: String?
    private(set) var latest: HeartRateMeasurement?
    private(set) var latestAt: Date?
    private(set) var packetCount = 0

    /// Every reading, for the heart rate zone.
    @ObservationIgnored var onReading: (@MainActor (Int) -> Void)?

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var watch: CBPeripheral?
    /// Demo mode (simulator screenshots): a fixed reading and no Bluetooth.
    @ObservationIgnored private var demoBPM: Int?

    private static let serviceID = CBUUID(string: "180D")
    private static let measurementID = CBUUID(string: "2A37")
    private static let savedWatchKey = "heartRateWatchID"

    override init() {
        super.init()
        if DemoMode.isOn {
            state = .connected
            deviceName = "Forerunner 165"
            demoBPM = 142
            return
        }
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.jlmoh.bikedash.heart-rate",
        ])
    }

    /// The latest heart rate, or nil once the broadcast has been quiet for `staleAfter`.
    func bpm(at now: Date) -> Int? {
        if let demoBPM { return demoBPM }
        guard let latest, let latestAt, now.timeIntervalSince(latestAt) <= Self.staleAfter else {
            return nil
        }
        return latest.bpm
    }

    var statusText: String {
        switch state {
        case .starting: return "Starting Bluetooth"
        case .bluetoothOff: return "Bluetooth is off"
        case .notAllowed: return "Bluetooth not allowed (Settings > Bike Dash)"
        case .unsupported: return "No Bluetooth LE"
        case .searching: return "Looking for a broadcast"
        case .waiting: return "Waiting for the watch"
        case .connected: return "Connected"
        }
    }

    /// Forgets the remembered watch and looks for one again.
    func forgetWatch() {
        if let watch { central?.cancelPeripheralConnection(watch) }
        watch = nil
        deviceName = nil
        latest = nil
        latestAt = nil
        UserDefaults.standard.removeObject(forKey: Self.savedWatchKey)
        findWatch()
    }

    // MARK: - Finding and keeping the watch

    private var savedWatchID: UUID? {
        UserDefaults.standard.string(forKey: Self.savedWatchKey).flatMap { UUID(uuidString: $0) }
    }

    private func findWatch() {
        guard let central, central.state == .poweredOn else { return }
        if let watch {
            // Restored by iOS after a background relaunch, or found earlier.
            if watch.state == .connected { subscribe(watch) } else { link(watch) }
            return
        }
        // Garmin Connect may already hold the watch's Bluetooth link, so check
        // peripherals the phone is connected to as well as the remembered one.
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceID])
        if let id = savedWatchID {
            if let match = connected.first(where: { $0.identifier == id })
                ?? central.retrievePeripherals(withIdentifiers: [id]).first {
                link(match)
                return
            }
        } else if let first = connected.first {
            link(first)
            return
        }
        state = .searching
        central.scanForPeripherals(withServices: [Self.serviceID])
    }

    private func link(_ peripheral: CBPeripheral) {
        guard let central else { return }
        if central.isScanning { central.stopScan() }
        adopt(peripheral)
        state = .waiting
        // A pending connect never times out: iOS completes it whenever the
        // watch broadcasts again, which is what makes reconnecting automatic.
        central.connect(peripheral)
    }

    private func adopt(_ peripheral: CBPeripheral) {
        watch = peripheral
        peripheral.delegate = self
        if let name = peripheral.name { deviceName = name }
    }

    private func subscribe(_ peripheral: CBPeripheral) {
        state = .connected
        if let name = peripheral.name { deviceName = name }
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedWatchKey)
        peripheral.discoverServices([Self.serviceID])
    }

    private func retryLater(_ peripheral: CBPeripheral) {
        state = .waiting
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.watch?.identifier == peripheral.identifier else { return }
            self.central?.connect(peripheral)
        }
    }
}

extension HeartRateService: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: findWatch()
        case .poweredOff: state = .bluetoothOff
        case .unauthorized: state = .notAllowed
        case .unsupported: state = .unsupported
        default: state = .starting
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            adopt(restored)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Once a watch is remembered, ignore other riders' straps on group rides.
        if let id = savedWatchID, peripheral.identifier != id { return }
        guard watch == nil else { return }
        if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String { deviceName = name }
        log.info("Found \(peripheral.name ?? "an unnamed device", privacy: .public), RSSI \(RSSI.intValue)")
        link(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == watch?.identifier else {
            // For example a connect left over from before "Forget watch".
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log.info("Connected to \(peripheral.name ?? "the watch", privacy: .public)")
        subscribe(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == watch?.identifier else { return }
        log.error("Connect failed: \(error?.localizedDescription ?? "unknown error", privacy: .public)")
        retryLater(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral.identifier == watch?.identifier else { return }
        log.info("Disconnected: \(error?.localizedDescription ?? "no error", privacy: .public)")
        state = .waiting
        central.connect(peripheral)
    }
}

extension HeartRateService: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
            log.notice("No heart rate service yet (is the watch broadcasting?)")
            return
        }
        peripheral.discoverCharacteristics([Self.measurementID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // The watch adds or drops the heart rate service as broadcasting starts and stops.
        peripheral.discoverServices([Self.serviceID])
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.measurementID }) else {
            return
        }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Self.measurementID,
              let data = characteristic.value,
              let measurement = HeartRateMeasurement(data: data) else { return }
        latest = measurement
        latestAt = Date()
        packetCount += 1
        onReading?(measurement.bpm)
    }
}
