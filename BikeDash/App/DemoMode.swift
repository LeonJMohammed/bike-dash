import BikeDashCore
import Foundation

/// For simulator screenshots only. Launch with
/// `-demo ride|fallback|lap|paused|finished|idle|history|route|routeTurn|offRoute`,
/// and optionally `-sheet routes|history|settings` and
/// `-page sensors|sensorData|routePreview`.
/// Every scene has a few Strava routes listed and a block round the Savannah
/// saved; `idle` and the route scenes have it picked, so they show the map.
/// Shows fake data, uses no Bluetooth, GPS, barometer or Spotify, and saves nothing.
/// The ride scenes send the same sensor packets the real sensors would, so the
/// sensor maths runs as it does on the bike; `fallback` has the speed sensor
/// switched off, so GPS takes over. The route scenes ride the block: `route`
/// mid-way along a side, `routeTurn` just before a corner, `offRoute` 60 m off it.
enum DemoMode {
    static let scene: String? = UserDefaults.standard.string(forKey: "demo")
    static var isOn: Bool { scene != nil }

    private static let metresPerDegree = GPSFix.earthRadius * .pi / 180

    /// The route scenes, and where on the block each ends its replay (metres).
    private static let routeTargets = ["route": 1100.0, "routeTurn": 1545, "offRoute": 1100]
    private static var followsRoute: Bool { scene.map { routeTargets[$0] != nil } ?? false }
    @MainActor private static var demoRoute: Route?
    /// Replayed distance + this = metres along the block.
    @MainActor private static var routeShift = 0.0
    /// From this replayed distance on, `offRoute` rides 60 m to the side.
    @MainActor private static var offFrom = Double.infinity

    /// Where a replayed ride has got to.
    private struct Progress {
        var second = 0
        var north = 0.0
        var wheelTurns = 0.0
        var crankTurns = 0.0
    }

    @MainActor
    static func load(ride: RideController, spotify: SpotifyController, history: RideHistory, routes: RouteLibrary) {
        spotify.loadDemo()
        loadRoutes(routes, pick: scene == "idle" || followsRoute)
        switch scene {
        case "idle":
            break
        case "history":
            for (daysAgo, minutes, kmh) in [(1, 42.0, 27.3), (3, 65.0, 25.1), (6, 31.0, 28.8)] {
                if var record = record(daysAgo: daysAgo, minutes: minutes, kmh: kmh) {
                    if daysAgo == 1 {
                        record.routeName = "Savannah block"
                        record.batteryAtStart = 94
                        record.batteryAtEnd = 86
                    }
                    history.add(record)
                }
            }
        default:
            if followsRoute, let scene, let target = routeTargets[scene] {
                // Where the replay ends: `target` metres along the block.
                let travelled = (0...2530).reduce(0.0) { $0 + speedAt($1) }
                routeShift = target - travelled
                offFrom = scene == "offRoute" ? travelled - 150 : .infinity
            }
            let progress = replay(into: ride, seconds: 2530)
            switch scene {
            case "paused": ride.pause()
            case "finished": ride.finish()
            case "lap":
                ride.lap()
                keepRiding(ride, from: progress)
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
            ride.addDemoCadence(cadenceAt(second))
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
        if followsRoute {
            if let fix = routeFix(at: time, travelled: progress.north, speed: speed) {
                ride.location.onFix?(fix)
            }
        } else {
            ride.location.onFix?(fix(at: time, north: progress.north, speed: speed))
        }

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
        var session = RideSession(settings: RideSession.Settings(autoLapDistance: 5000))
        session.start(at: start)
        for second in 0...seconds {
            session.add(fix(at: start.addingTimeInterval(Double(second)), north: Double(second) * speed, speed: speed))
            if second % 10 == 0 { session.addHeartRate(132 + second % 17) }
            session.addCadence(cadenceAt(second))
            if second % 30 == 0 { session.addAltitude(Double(second % 600) / 10) }
        }
        session.finish(at: start.addingTimeInterval(Double(seconds)))
        return session.record()
    }

    /// Listed Strava routes, with a block round the Savannah saved (and picked).
    @MainActor
    private static func loadRoutes(_ routes: RouteLibrary, pick: Bool) {
        let gpx = savannahGPX()
        demoRoute = try? Route.parseGPX(gpx, fallbackName: "Savannah block")
        let loop = StravaRoute(id: "3344550000000000123", name: "Savannah block", kind: .ride, distance: 4200,
                               elevationGain: 26, updatedAt: "2026-11-02T09:00:00Z")
        let listed = [
            loop,
            StravaRoute(id: "3344550000000000456", name: "Chaguaramas out and back", kind: .ride, distance: 32_400,
                        elevationGain: 118, updatedAt: "2026-10-18T07:30:00Z", isPrivate: true),
            StravaRoute(id: "3344550000000000789", name: "Maracas climb", kind: .ride, distance: 41_800,
                        elevationGain: 612, updatedAt: "2026-09-27T06:10:00Z", starred: true),
            StravaRoute(id: "3344550000000000999", name: "Grand Stand 5K", kind: .run, distance: 5080,
                        elevationGain: 25, updatedAt: "2026-10-23T05:00:00Z"),
        ]
        routes.loadDemo(strava: listed, saved: loop, gpx: gpx, pick: pick)
    }

    /// A block 1.2 km by 0.9 km round the Savannah, clockwise from the middle of
    /// the north side (four right turns), a point every 25 m, a gentle rise north.
    private static func savannahGPX() -> Data {
        let centre = (lat: 10.6705, lon: -61.5135)
        let east = metresPerDegree * cos(centre.lat * .pi / 180)
        let corners: [(north: Double, east: Double)] = [(600, 0), (600, 450), (-600, 450), (-600, -450), (600, -450), (600, 0)]
        var body = ""
        func add(_ north: Double, _ eastward: Double) {
            let ele = 22 + 12 * north / 600 + 2 * sin(eastward / 90)
            body += String(format: "<trkpt lat=\"%.6f\" lon=\"%.6f\"><ele>%.1f</ele></trkpt>\n",
                           centre.lat + north / metresPerDegree, centre.lon + eastward / east, ele)
        }
        add(corners[0].north, corners[0].east)
        for (a, b) in zip(corners, corners.dropFirst()) {
            let length = abs(b.north - a.north) + abs(b.east - a.east)
            let steps = Int(length / 25)
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                add(a.north + t * (b.north - a.north), a.east + t * (b.east - a.east))
            }
        }
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx creator="StravaGPX" version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>Savannah block</name><trkseg>
        \(body)</trkseg></trk>
        </gpx>
        """.utf8)
    }

    /// A route scene's GPS fix: on the block (none before its start), with the
    /// course the phone would give, or 60 m to the side for `offRoute`.
    @MainActor
    private static func routeFix(at time: Date, travelled: Double, speed: Double) -> GPSFix? {
        guard let route = demoRoute else { return nil }
        let along = travelled + routeShift
        guard along >= 0, along <= route.length else { return nil }
        let course = Geo.bearing(route.point(atDistance: along - 5), route.point(atDistance: along + 5))
        var point = route.point(atDistance: along)
        if travelled >= offFrom {
            point = Geo.offset(point, bearing: course + 90, distance: 60)
        }
        return GPSFix(time: time, latitude: point.latitude, longitude: point.longitude,
                      horizontalAccuracy: 4, speed: speed, course: course)
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
