import Foundation

/// What a cycling sensor sends, judged from its measurement flags (never its name).
public enum CSCSensorKind: String, Codable, Equatable, Sendable {
    case speed
    case cadence
    case speedAndCadence

    public var sendsWheel: Bool { self != .cadence }
    public var sendsCrank: Bool { self != .speed }
}

/// One packet from the standard Bluetooth CSC Measurement characteristic
/// (0x2A5B, in the Cycling Speed and Cadence service 0x1816).
///
/// Layout, little-endian: a flags byte; if bit 0 is set, wheel data (UInt32
/// cumulative revolutions, UInt16 last event time); if bit 1 is set, crank data
/// (UInt16 cumulative revolutions, UInt16 last event time). Event times are in
/// 1/1024 s and wrap every 64 s.
public struct CSCMeasurement: Equatable, Sendable {
    public struct Wheel: Equatable, Sendable {
        public var revolutions: UInt32
        public var eventTime: UInt16

        public init(revolutions: UInt32, eventTime: UInt16) {
            self.revolutions = revolutions
            self.eventTime = eventTime
        }
    }

    public struct Crank: Equatable, Sendable {
        public var revolutions: UInt16
        public var eventTime: UInt16

        public init(revolutions: UInt16, eventTime: UInt16) {
            self.revolutions = revolutions
            self.eventTime = eventTime
        }
    }

    public let flags: UInt8
    public let wheel: Wheel?
    public let crank: Crank?

    public init(wheel: Wheel?, crank: Crank?) {
        self.wheel = wheel
        self.crank = crank
        flags = (wheel == nil ? 0 : 0x01) | (crank == nil ? 0 : 0x02)
    }

    /// Returns nil when the packet is shorter than its flags promise.
    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        var index = 1

        if flags & 0x01 != 0 {
            guard bytes.count >= index + 6 else { return nil }
            wheel = Wheel(
                revolutions: Self.uint32(bytes, at: index),
                eventTime: Self.uint16(bytes, at: index + 4)
            )
            index += 6
        } else {
            wheel = nil
        }

        if flags & 0x02 != 0 {
            guard bytes.count >= index + 4 else { return nil }
            crank = Crank(
                revolutions: Self.uint16(bytes, at: index),
                eventTime: Self.uint16(bytes, at: index + 2)
            )
        } else {
            crank = nil
        }
        self.flags = flags
    }

    /// Nil when the packet carries neither wheel nor crank data.
    public var kind: CSCSensorKind? {
        switch (wheel != nil, crank != nil) {
        case (true, true): return .speedAndCadence
        case (true, false): return .speed
        case (false, true): return .cadence
        case (false, false): return nil
        }
    }

    private static func uint16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index])
            | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
    }
}
