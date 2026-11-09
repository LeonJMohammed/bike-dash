import BikeDashCore
import Foundation

/// For simulator screenshots only. Launch with
/// `-demo ride|fallback|paused|finished|idle|history`, and optionally
/// `-sheet history|settings` and `-page sensors|sensorData`.
/// Shows fake data, uses no Bluetooth, GPS, barometer or Spotify, and saves nothing.
/// The ride scenes send the same sensor packets the real sensors would, so the
/// sensor maths runs as it does on the bike; `fallback` has the speed sensor
/// switched off, so GPS takes over.
enum DemoMode {
    static let scene: String? = UserDefaults.standard.string(forKey: "demo")
    static var isOn: Bool { scene != nil }

    private static let metresPerDegree = GPSFix.earthRadius * .pi / 180

    /// Where a replayed ride has got to.
    private struct Progress {
        var second = 0
        var north = 0.0
        var wheelTurns = 0.0
        var crankTurns = 0.0
    }

    @MainActor
    static func load(ride: RideController, spotify: SpotifyController, history: RideHistory) {
        spotify.loadDemo()
        switch scene {
        case "idle":
            break
        case "history":
            for (daysAgo, minutes, kmh) in [(1, 42.0, 27.3), (3, 65.0, 25.1), (6, 31.0, 28.8)] {
                if let record = record(daysAgo: daysAgo, minutes: minutes, kmh: kmh) {
                    history.add(record)
                }
            }
        default:
            let progress = replay(into: ride, seconds: 2530)
            switch scene {
            case "paused": ride.pause()
            case "finished": ride.finish()
            default: keepRiding(ride, from: progress)
            }
        }
    }

    /// A ride of `seconds` that started that long ago.
    @MainActor
    private static func replay(into ride: RideController, seconds: Int) -> Progress {
        let start = Date().addingTimeInterval(-Double(seconds))
        ride.start(at: start)
        var progress = Progress()
        for second in 0...seconds {
            progress.second = second
            step(ride, &progress, at: start.addingTimeInterval(Double(second)))
            if second % 5 == 0 {
                ride.altimeter.onAltitude?(86 * Double(second) / Double(seconds))
            }
            if second % 10 == 0 {
                ride.addDemoHeartRate(136 + second % 11)
            }
        }
        return progress
    }

    @MainActor
    private static func keepRiding(_ ride: RideController, from progress: Progress) {
        Task { @MainActor in
            var progress = progress
            while true {
                try? await Task.sleep(for: .seconds(1))
                progress.second += 1
                step(ride, &progress, at: Date())
            }
        }
    }

    /// One second of riding: a GPS fix, and the packets the speed and cadence
    /// sensors would send (their clocks count from the start of the ride).
    @MainActor
    private static func step(_ ride: RideController, _ progress: inout Progress, at time: Date) {
        let clock = Double(progress.second)
        let speed = speedAt(progress.second)
        progress.north += speed
        ride.location.onFix?(fix(at: time, north: progress.north, speed: speed))

        if scene != "fallback" {
            let circumference = ride.sensors.circumferenceMetres
            progress.wheelTurns += speed / circumference
            let turns = progress.wheelTurns.rounded(.down)
            let lastTurn = clock - (progress.wheelTurns - turns) * circumference / speed
            let wheel = CSCMeasurement.Wheel(revolutions: UInt32(turns), eventTime: ticks(lastTurn))
            ride.sensors.receiveDemo(CSCMeasurement(wheel: wheel, crank: nil), from: .speed, at: time)
        }

        let perSecond = cadenceAt(progress.second) / 60
        progress.crankTurns += perSecond
        let turns = progress.crankTurns.rounded(.down)
        let lastTurn = clock - (progress.crankTurns - turns) / perSecond
        let crank = CSCMeasurement.Crank(revolutions: UInt16(truncatingIfNeeded: Int(turns)), eventTime: ticks(lastTurn))
        ride.sensors.receiveDemo(CSCMeasurement(wheel: nil, crank: crank), from: .cadence, at: time)
    }

    private static func record(daysAgo: Int, minutes: Double, kmh: Double) -> RideRecord? {
        let start = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        let seconds = Int(minutes * 60)
        let speed = kmh / 3.6
        var session = RideSession()
        session.start(at: start)
        for second in 0...seconds {
            session.add(fix(at: start.addingTimeInterval(Double(second)), north: Double(second) * speed, speed: speed))
            if second % 10 == 0 { session.addHeartRate(132 + second % 17) }
            if second % 30 == 0 { session.addAltitude(Double(second % 600) / 10) }
        }
        session.finish(at: start.addingTimeInterval(Double(seconds)))
        return session.record()
    }

    /// About 27 km/h, drifting a little.
    private static func speedAt(_ second: Int) -> Double {
        7.6 + 0.8 * sin(Double(second) / 40)
    }

    /// About 88 rpm.
    private static func cadenceAt(_ second: Int) -> Double {
        88 + 4 * sin(Double(second) / 25)
    }

    /// A sensor clock reading: 1/1024 s ticks, wrapping every 64 s.
    private static func ticks(_ seconds: Double) -> UInt16 {
        UInt16(truncatingIfNeeded: Int((seconds * 1024).rounded()))
    }

    private static func fix(at time: Date, north: Double, speed: Double) -> GPSFix {
        GPSFix(
            time: time,
            latitude: 10.65 + north / metresPerDegree,
            longitude: -61.5,
            horizontalAccuracy: 4,
            speed: speed
        )
    }
}
