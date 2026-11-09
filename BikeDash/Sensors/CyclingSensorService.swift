import BikeDashCore
import CoreBluetooth
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.jlmoh.bikedash", category: "sensors")

/// Speed and cadence from Bluetooth cycling sensors: the standard Cycling Speed
/// and Cadence service (0x1816), as the Magene S3+ sends it. One sensor sits on
/// the front hub in speed mode, the other on the crank in cadence mode.
///
/// - What a sensor sends comes from its measurement flags, never its name.
/// - Paired sensors are saved and reconnected whenever they wake up: a pending
///   connect never times out, so iOS completes it when the sensor advertises.
/// - It has its own Bluetooth central, so the heart rate side is untouched.
@MainActor
@Observable
final class CyclingSensorService: NSObject {
    enum Role: String, CaseIterable, Identifiable {
        case speed, cadence
        var id: String { rawValue }
        var title: String { self == .speed ? "Speed" : "Cadence" }
    }

    enum Bluetooth: Equatable {
        case starting, on, off, notAllowed, unsupported
    }

    enum Link: Equatable {
        case disconnected
        case connecting
        /// Connected, with measurements switched on.
        case connected
    }

    /// The sensor paired for a role.
    struct Pairing: Codable, Equatable {
        var id: UUID
        var name: String
    }

    /// A sensor the phone is talking to: a paired one, or one found while pairing.
    struct Device: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int?
        var link: Link = .disconnected
        /// From the flags of its latest measurement; nil until one arrives.
        var kind: CSCSensorKind?
        var packets = 0
        var lastPacketAt: Date?
        var latest: CSCMeasurement?
    }

    /// Sent to the ride on every packet and connection change.
    struct Update {
        let at: Date
        /// New wheel revolutions from the speed sensor...
        var wheelRevolutions = 0
        /// ...since the packet before, which arrived at this time.
        var wheelSince: Date?
        /// Set when this packet ends a stop: the wheel stood still from then.
        var wheelStoppedSince: Date?
    }

    struct WheelSize: Identifiable {
        let name: String
        let millimetres: Int
        var id: Int { millimetres }
    }

    static let defaultCircumference = 2105
    static let circumferenceRange = 1000...3000
    /// Common 700c sizes, from the Garmin wheel-size chart.
    static let commonWheels = [
        WheelSize(name: "700x23", millimetres: 2096),
        WheelSize(name: "700x25", millimetres: 2105),
        WheelSize(name: "700x28", millimetres: 2136),
        WheelSize(name: "700x30", millimetres: 2146),
        WheelSize(name: "700x32", millimetres: 2155),
        WheelSize(name: "700x35", millimetres: 2168),
        WheelSize(name: "700x38", millimetres: 2180),
    ]

    private(set) var bluetooth: Bluetooth = .starting
    private(set) var paired: [Role: Pairing] = [:]
    private(set) var devices: [UUID: Device] = [:]
    private(set) var isScanning = false
    private(set) var wheel = RevolutionCounter.wheel()
    private(set) var crank = RevolutionCounter.crank()
    /// Wheel circumference in millimetres.
    private(set) var circumference = CyclingSensorService.defaultCircumference

    @ObservationIgnored var onUpdate: (@MainActor (Update) -> Void)?

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var wantsScan = false

    private static let serviceID = CBUUID(string: "1816")
    private static let measurementID = CBUUID(string: "2A5B")
    private static let circumferenceKey = "wheelCircumference"
    /// While pairing, it connects to this many unpaired sensors to learn what they send.
    private static let maxFound = 8

    override init() {
        super.init()
        let stored = UserDefaults.standard.integer(forKey: Self.circumferenceKey)
        if Self.circumferenceRange.contains(stored) { circumference = stored }
        if DemoMode.isOn {
            loadDemo()
            return
        }
        for role in Role.allCases {
            if let data = UserDefaults.standard.data(forKey: Self.pairingKey(role)),
               let pairing = try? JSONDecoder().decode(Pairing.self, from: data) {
                paired[role] = pairing
                devices[pairing.id] = Device(id: pairing.id, name: pairing.name)
            }
        }
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.jlmoh.bikedash.cycling-sensors",
        ])
    }

    // MARK: - Readings

    var circumferenceMetres: Double { Double(circumference) / 1000 }

    func isPaired(_ id: UUID) -> Bool {
        paired.values.contains { $0.id == id }
    }

    /// The sensor paired for `role`.
    func device(_ role: Role) -> Device? {
        paired[role].flatMap { devices[$0.id] }
    }

    /// The link to the sensor paired for `role`; nil when none is paired.
    func link(_ role: Role) -> Link? {
        guard let id = paired[role]?.id else { return nil }
        return devices[id]?.link ?? .disconnected
    }

    func isConnected(_ role: Role) -> Bool {
        bluetooth == .on && link(role) == .connected
    }

    /// m/s: 0 once the wheel has stopped, nil without a connected speed sensor.
    func speed(at now: Date) -> Double? {
        guard isConnected(.speed) else { return nil }
        return wheel.rate(at: now) * circumferenceMetres
    }

    /// rpm: 0 when not pedalling, nil without a connected cadence sensor.
    func cadence(at now: Date) -> Double? {
        guard isConnected(.cadence) else { return nil }
        return crank.rate(at: now) * 60
    }

    /// When the wheel last turned (the latest new revolution).
    var wheelLastTurnedAt: Date? { wheel.lastRevolutionAt }

    func statusText(_ role: Role) -> String {
        guard let link = link(role) else { return "Not paired" }
        switch bluetooth {
        case .off: return "Bluetooth is off"
        case .notAllowed: return "Bluetooth not allowed"
        case .unsupported: return "No Bluetooth LE"
        case .starting: return "Starting Bluetooth"
        case .on: break
        }
        switch link {
        case .connected: return "Connected"
        case .connecting, .disconnected: return role == .speed ? "Waiting: spin the wheel" : "Waiting: turn the crank"
        }
    }

    // MARK: - Settings and pairing

    func setCircumference(_ millimetres: Int) {
        guard Self.circumferenceRange.contains(millimetres) else { return }
        circumference = millimetres
        if !DemoMode.isOn { UserDefaults.standard.set(millimetres, forKey: Self.circumferenceKey) }
    }

    /// Pairs a sensor for what it sends: speed, cadence or both.
    func use(_ id: UUID) {
        guard let device = devices[id], let kind = device.kind else { return }
        if kind.sendsWheel { pair(device, as: .speed) }
        if kind.sendsCrank { pair(device, as: .cadence) }
        onUpdate?(Update(at: Date()))
    }

    func forget(_ role: Role) {
        guard let pairing = paired[role] else { return }
        paired[role] = nil
        savePairing(role)
        restartCount(role)
        release(pairing.id)
        onUpdate?(Update(at: Date()))
    }

    /// The pairing screen: scan, and connect to what's found to learn what it sends.
    func startScan() {
        wantsScan = true
        if DemoMode.isOn {
            isScanning = true
            return
        }
        beginScan()
    }

    /// Leaving the pairing screen: stop scanning and let go of sensors not chosen.
    func stopScan() {
        wantsScan = false
        isScanning = false
        guard let central else { return }
        if central.state == .poweredOn { central.stopScan() }
        for (id, peripheral) in peripherals where !isPaired(id) {
            central.cancelPeripheralConnection(peripheral)
            peripherals[id] = nil
            devices[id] = nil
        }
    }

    /// Demo mode: a packet as if it came from the sensor paired for `role`.
    func receiveDemo(_ measurement: CSCMeasurement, from role: Role, at time: Date) {
        guard let id = paired[role]?.id else { return }
        handle(measurement, from: id, at: time)
    }

    // MARK: - Private

    private static func pairingKey(_ role: Role) -> String {
        "sensor.\(role.rawValue)"
    }

    private func pair(_ device: Device, as role: Role) {
        let previous = paired[role]
        paired[role] = Pairing(id: device.id, name: device.name)
        savePairing(role)
        restartCount(role)
        if let previous, previous.id != device.id { release(previous.id) }
        log.info("Paired \(device.name, privacy: .public) for \(role.rawValue, privacy: .public)")
    }

    private func savePairing(_ role: Role) {
        guard !DemoMode.isOn else { return }
        if let pairing = paired[role], let data = try? JSONEncoder().encode(pairing) {
            UserDefaults.standard.set(data, forKey: Self.pairingKey(role))
        } else {
            UserDefaults.standard.removeObject(forKey: Self.pairingKey(role))
        }
    }

    private func restartCount(_ role: Role) {
        switch role {
        case .speed: wheel.reset()
        case .cadence: crank.reset()
        }
    }

    /// Disconnects a sensor no role uses any more. While the pairing screen is
    /// open it stays, listed under Nearby.
    private func release(_ id: UUID) {
        guard !isPaired(id), !wantsScan else { return }
        if let peripheral = peripherals[id] { central?.cancelPeripheralConnection(peripheral) }
        peripherals[id] = nil
        devices[id] = nil
    }

    /// Whether it should stay connected to this sensor.
    private func wanted(_ id: UUID) -> Bool {
        isPaired(id) || (wantsScan && devices[id] != nil)
    }

    private func connectPaired() {
        guard let central, central.state == .poweredOn else { return }
        // Let go of anything restored that isn't paired (left over from pairing).
        for (id, peripheral) in peripherals where !wanted(id) {
            central.cancelPeripheralConnection(peripheral)
            peripherals[id] = nil
            devices[id] = nil
        }
        // A sensor another app on this phone holds is only in the connected list.
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceID])
        for id in Set(paired.values.map(\.id)) {
            if let peripheral = peripherals[id]
                ?? connected.first(where: { $0.identifier == id })
                ?? central.retrievePeripherals(withIdentifiers: [id]).first {
                open(peripheral)
            }
        }
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn else { return }
        isScanning = true
        // Sensors connected through another app on this phone don't advertise.
        for peripheral in central.retrieveConnectedPeripherals(withServices: [Self.serviceID])
        where devices[peripheral.identifier] == nil {
            devices[peripheral.identifier] = Device(id: peripheral.identifier, name: peripheral.name ?? "Unnamed sensor")
            open(peripheral)
        }
        central.scanForPeripherals(withServices: [Self.serviceID])
    }

    /// Connects, or keeps a connect pending until the sensor wakes up.
    private func open(_ peripheral: CBPeripheral) {
        adopt(peripheral)
        if peripheral.state == .connected {
            peripheral.discoverServices([Self.serviceID])
        } else {
            setLink(.connecting, for: peripheral.identifier)
            central?.connect(peripheral)
        }
    }

    private func adopt(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        peripherals[id] = peripheral
        peripheral.delegate = self
        if devices[id] == nil {
            devices[id] = Device(id: id, name: peripheral.name ?? "Sensor")
        }
    }

    private func setLink(_ link: Link, for id: UUID) {
        guard var device = devices[id], device.link != link else { return }
        device.link = link
        devices[id] = device
    }

    private func retryLater(_ id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.wanted(id), let peripheral = self.peripherals[id],
                  peripheral.state != .connected else { return }
            self.setLink(.connecting, for: id)
            self.central?.connect(peripheral)
        }
    }

    private func handle(_ measurement: CSCMeasurement, from id: UUID, at now: Date) {
        guard var device = devices[id] else { return }
        device.packets += 1
        device.lastPacketAt = now
        device.latest = measurement
        device.link = .connected
        if let kind = measurement.kind { device.kind = kind }
        devices[id] = device

        var update = Update(at: now)
        if paired[.speed]?.id == id, let data = measurement.wheel {
            update.wheelSince = wheel.last?.receivedAt
            let result = wheel.add(revolutions: data.revolutions, eventTime: data.eventTime, at: now)
            update.wheelRevolutions = result.revolutions
            update.wheelStoppedSince = result.stoppedSince
        }
        if paired[.cadence]?.id == id, let data = measurement.crank {
            crank.add(revolutions: UInt32(data.revolutions), eventTime: data.eventTime, at: now)
        }
        onUpdate?(update)
    }

    /// Demo mode (simulator screenshots): two paired sensors and two more nearby.
    private func loadDemo() {
        bluetooth = .on
        let speed = Pairing(id: UUID(), name: "Magene S3+ 4821")
        let cadence = Pairing(id: UUID(), name: "Magene S3+ 7394")
        paired = [.speed: speed, .cadence: cadence]
        let speedLink: Link = DemoMode.scene == "fallback" ? .connecting : .connected
        devices[speed.id] = Device(id: speed.id, name: speed.name, rssi: -61, link: speedLink, kind: .speed)
        devices[cadence.id] = Device(id: cadence.id, name: cadence.name, rssi: -55, link: .connected, kind: .cadence)
        let nearby: [(String, Int, CSCSensorKind?)] = [("Magene S3+ 1166", -74, nil), ("Wahoo CADENCE 2B1F", -83, .cadence)]
        for (name, rssi, kind) in nearby {
            let id = UUID()
            devices[id] = Device(id: id, name: name, rssi: rssi, link: .connected, kind: kind)
        }
    }
}

extension CyclingSensorService: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetooth = .on
            connectPaired()
            if wantsScan { beginScan() }
        case .poweredOff:
            bluetooth = .off
            for id in devices.keys { setLink(.disconnected, for: id) }
        case .unauthorized:
            bluetooth = .notAllowed
        case .unsupported:
            bluetooth = .unsupported
        default:
            bluetooth = .starting
        }
        onUpdate?(Update(at: Date()))
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        for peripheral in dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? [] {
            adopt(peripheral)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        if var device = devices[id] {
            device.rssi = RSSI.intValue
            if let name { device.name = name }
            devices[id] = device
            return
        }
        let found = devices.keys.filter { !isPaired($0) }.count
        guard wantsScan, found < Self.maxFound else { return }
        log.info("Found \(name ?? "an unnamed sensor", privacy: .public), RSSI \(RSSI.intValue)")
        devices[id] = Device(id: id, name: name ?? "Unnamed sensor", rssi: RSSI.intValue)
        // Connect to learn what it sends, from the flags of its first measurement.
        open(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard wanted(id) else {
            // For example a connect left over from the pairing screen.
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log.info("Connected to \(peripheral.name ?? "a sensor", privacy: .public)")
        if let name = peripheral.name, var device = devices[id], device.name != name {
            device.name = name
            devices[id] = device
        }
        peripheral.discoverServices([Self.serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("Connect failed: \(error?.localizedDescription ?? "unknown error", privacy: .public)")
        setLink(.disconnected, for: peripheral.identifier)
        retryLater(peripheral.identifier)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let id = peripheral.identifier
        log.info("Disconnected from \(peripheral.name ?? "a sensor", privacy: .public): \(error?.localizedDescription ?? "no error", privacy: .public)")
        if wanted(id) {
            // Reconnects by itself whenever the sensor wakes up again.
            setLink(.connecting, for: id)
            central.connect(peripheral)
        } else {
            setLink(.disconnected, for: id)
        }
        onUpdate?(Update(at: Date()))
    }
}

extension CyclingSensorService: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
            log.notice("No speed and cadence service on \(peripheral.name ?? "the sensor", privacy: .public)")
            return
        }
        peripheral.discoverCharacteristics([Self.measurementID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
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
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Self.measurementID else { return }
        if let error {
            log.error("Couldn't switch measurements on: \(error.localizedDescription, privacy: .public)")
            return
        }
        if characteristic.isNotifying {
            setLink(.connected, for: peripheral.identifier)
            onUpdate?(Update(at: Date()))
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Self.measurementID,
              let data = characteristic.value,
              let measurement = CSCMeasurement(data: data) else { return }
        handle(measurement, from: peripheral.identifier, at: Date())
    }
}
