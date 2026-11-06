import BikeDashCore
import Foundation

/// For simulator screenshots only. Launch with `-demo ride|paused|finished|idle|history`,
/// and optionally `-tab history|computer|settings` and `-page 1` (music).
/// Shows fake data, uses no Bluetooth, GPS, barometer or Spotify, and saves nothing.
enum DemoMode {
    static let scene: String? = UserDefaults.standard.string(forKey: "demo")
    static var isOn: Bool { scene != nil }

    private static let metresPerDegree = GPSFix.earthRadius * .pi / 180

    @MainActor
    static func load(ride: RideController, spotify: SpotifyController, history: RideHistory) {
        spotify.loadDemo()
        ride.location.startDemo()
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
            let north = replay(into: ride, seconds: 2530)
            switch scene {
            case "paused": ride.pause()
            case "finished": ride.finish()
            default: keepRiding(ride, second: 2530, north: north)
            }
        }
    }

    /// A ride of `seconds` that started that long ago. Returns where it got to.
    @MainActor
    private static func replay(into ride: RideController, seconds: Int) -> Double {
        let start = Date().addingTimeInterval(-Double(seconds))
        ride.start(at: start)
        var north = 0.0
        for second in 0...seconds {
            let speed = speedAt(second)
            north += speed
            ride.location.onFix?(fix(at: start.addingTimeInterval(Double(second)), north: north, speed: speed))
            if second % 5 == 0 {
                ride.altimeter.onAltitude?(86 * Double(second) / Double(seconds))
            }
            if second % 10 == 0 {
                ride.addDemoHeartRate(136 + second % 11)
            }
        }
        return north
    }

    @MainActor
    private static func keepRiding(_ ride: RideController, second: Int, north: Double) {
        Task { @MainActor in
            var second = second
            var north = north
            while true {
                try? await Task.sleep(for: .seconds(1))
                second += 1
                let speed = speedAt(second)
                north += speed
                ride.location.onFix?(fix(at: Date(), north: north, speed: speed))
            }
        }
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
