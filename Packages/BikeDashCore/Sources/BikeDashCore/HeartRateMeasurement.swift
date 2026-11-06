import Foundation

/// One packet from the standard Bluetooth Heart Rate Measurement
/// characteristic (0x2A37), as broadcast by the Forerunner 165.
public struct HeartRateMeasurement: Equatable, Sendable {
    public enum SensorContact: Equatable, Sendable {
        case notSupported
        case notDetected
        case detected
    }

    public let bpm: Int
    public let sensorContact: SensorContact
    /// Kilojoules since the sensor last reset, when the sensor sends it.
    public let energyExpended: Int?
    /// Beat-to-beat intervals in seconds, when the sensor sends them.
    public let rrIntervals: [Double]

    /// Returns nil when the packet is too short to hold a heart rate.
    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        var index = 1

        // Bit 0: heart rate is UInt16 instead of UInt8.
        if flags & 0x01 != 0 {
            guard bytes.count >= index + 2 else { return nil }
            bpm = Self.uint16(bytes, at: index)
            index += 2
        } else {
            guard bytes.count >= index + 1 else { return nil }
            bpm = Int(bytes[index])
            index += 1
        }

        // Bits 1-2: sensor contact status.
        switch (flags >> 1) & 0x03 {
        case 0x02: sensorContact = .notDetected
        case 0x03: sensorContact = .detected
        default: sensorContact = .notSupported
        }

        // Bit 3: energy expended is present.
        if flags & 0x08 != 0, bytes.count >= index + 2 {
            energyExpended = Self.uint16(bytes, at: index)
            index += 2
        } else {
            energyExpended = nil
        }

        // Bit 4: one or more RR intervals follow, in 1/1024 s.
        var intervals: [Double] = []
        if flags & 0x10 != 0 {
            while bytes.count >= index + 2 {
                intervals.append(Double(Self.uint16(bytes, at: index)) / 1024)
                index += 2
            }
        }
        rrIntervals = intervals
    }

    private static func uint16(_ bytes: [UInt8], at index: Int) -> Int {
        Int(bytes[index]) | Int(bytes[index + 1]) << 8
    }
}
