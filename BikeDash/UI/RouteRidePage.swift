import BikeDashCore
import MapKit
import SwiftUI

/// A number above the map in the route layout.
enum RouteStat {
    case speed, heartRate, toGo, time, distance, cadence
}

/// The route layout, in one place: change the rows here to move the numbers.
enum RouteRideLayout {
    /// Each row's numbers, left to right, and its share of the space above the map.
    static let rows: [(stats: [RouteStat], weight: CGFloat)] = [
        ([.speed, .heartRate], 1.6),
        ([.toGo, .time], 1),
    ]
    /// The share of the page (below the status strip) for the numbers; the map has the rest.
    static let numbersShare: CGFloat = 0.42
}

/// The ride screen when a route is picked: the status strip, the numbers in
/// `RouteRideLayout`, and the map following the rider, with the turn and
/// off-route banners across its top.
struct RouteRidePage: View {
    let ride: RideController
    let route: Route
    /// While the ride is under way; before it, the map shows the whole route.
    let navigator: RouteNavigator?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(spacing: 0) {
                StatusStrip(ride: ride, now: now)
                HorizontalRule()
                GeometryReader { geo in
                    let rows = RouteRideLayout.rows
                    let space = geo.size.height * RouteRideLayout.numbersShare - CGFloat(rows.count)
                    let total = rows.reduce(0) { $0 + $1.weight }
                    VStack(spacing: 0) {
                        ForEach(rows.indices, id: \.self) { r in
                            let height = space * rows[r].weight / total
                            HStack(spacing: 0) {
                                ForEach(rows[r].stats.indices, id: \.self) { i in
                                    if i > 0 { VerticalRule() }
                                    tile(rows[r].stats[i], now: now, size: height * 0.62)
                                }
                            }
                            .frame(height: height)
                            HorizontalRule()
                        }
                        RideMap(route: route, navigator: navigator)
                            .overlay(alignment: .top) { banner }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let navigator {
            if navigator.offRoute {
                OffRouteBanner(offset: navigator.offset)
            } else if let turn = navigator.turn {
                TurnBanner(turn: turn, distance: navigator.toTurn)
            }
        }
    }

    private func tile(_ stat: RouteStat, now: Date, size: CGFloat) -> MetricTile {
        let session = ride.session
        switch stat {
        case .speed:
            let speed = ride.speed(at: now)
            return MetricTile(label: "SPEED", value: speed.map { RideFormat.speed($0) } ?? "--", size: size,
                              labelColor: speed == nil ? Theme.warning : .white)
        case .heartRate:
            let bpm = ride.heartRate.bpm(at: now)
            return MetricTile(label: "HEART RATE", value: bpm.map { "\($0)" } ?? "--", size: size,
                              labelColor: bpm == nil ? Theme.warning : .white)
        case .toGo:
            // Riding to the start of the route: how far away it is.
            if let navigator, !navigator.joined, let offset = navigator.offset {
                return MetricTile(label: "TO ROUTE", value: RideFormat.distance(offset), size: size, labelColor: Theme.route)
            }
            return MetricTile(label: "TO GO", value: RideFormat.distance(navigator?.remaining ?? route.length), size: size)
        case .time:
            let label: String
            switch session.state {
            case .paused(.auto): label = "TIME · AUTO-PAUSED"
            case .paused(.manual): label = "TIME · PAUSED"
            default: label = "TIME"
            }
            return MetricTile(label: label, value: RideFormat.clock(session.movingTime(at: now)), size: size,
                              labelColor: session.isPaused ? Theme.paused : .white)
        case .distance:
            return MetricTile(label: "DISTANCE", value: RideFormat.distance(session.distance), size: size)
        case .cadence:
            let cadence = ride.sensors.cadence(at: now)
            return MetricTile(label: "CADENCE", value: cadence.map { RideFormat.cadence($0) } ?? "--", size: size)
        }
    }
}

/// The route on a dark map. During a ride it follows the rider, pointing the
/// way they're going, with the ridden part grey; before it, the whole route.
/// It can't be dragged, so a bump or rain doesn't move it.
struct RideMap: View {
    let route: Route
    let navigator: RouteNavigator?
    @State private var camera: MapCameraPosition = .automatic

    /// The map centre sits this far ahead of the rider, to show more of what's coming.
    static let lookAhead = 140.0
    /// Camera height in metres: a few streets either way.
    static let height = 1000.0

    var body: some View {
        let line = split(at: navigator?.position?.distanceAlong)
        Map(position: $camera, interactionModes: []) {
            if line.done.count >= 2 {
                MapPolyline(coordinates: line.done)
                    .stroke(Color(white: 0.45), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            MapPolyline(coordinates: line.ahead)
                .stroke(Theme.route, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            if let finish = route.points.last {
                Annotation("", coordinate: finish.coordinate, anchor: .bottomLeading) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black, radius: 2)
                }
            }
            if let turn = navigator?.turn {
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: turn.latitude, longitude: turn.longitude), anchor: .center) {
                    Circle().fill(Color.white)
                        .overlay(Circle().stroke(Color.black, lineWidth: 3))
                        .frame(width: 16, height: 16)
                }
            }
            if let rider = navigator?.rider {
                Annotation("", coordinate: rider.coordinate, anchor: .center) {
                    RiderMarker(hasHeading: navigator?.heading != nil, offRoute: navigator?.offRoute ?? false)
                }
            } else if navigator == nil, let start = route.points.first {
                Annotation("", coordinate: start.coordinate, anchor: .center) {
                    Circle().fill(Color.green)
                        .overlay(Circle().stroke(Color.black, lineWidth: 2))
                        .frame(width: 16, height: 16)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {}
        .environment(\.colorScheme, .dark)
        .onAppear { camera = followCamera() }
        .onChange(of: navigator?.rider) { camera = followCamera() }
    }

    /// Following the rider, heading up; the whole route before the first fix.
    private func followCamera() -> MapCameraPosition {
        guard let rider = navigator?.rider else { return .rect(RouteMap.fit(route)) }
        let heading = navigator?.heading ?? 0
        let centre = Geo.offset(rider, bearing: heading, distance: Self.lookAhead)
        return .camera(MapCamera(centerCoordinate: centre.coordinate, distance: Self.height, heading: heading, pitch: 0))
    }

    /// The route up to the rider, and from the rider to the finish.
    private func split(at progress: Double?) -> (done: [CLLocationCoordinate2D], ahead: [CLLocationCoordinate2D]) {
        guard let progress, progress > 0 else { return ([], route.points.map(\.coordinate)) }
        let here = route.point(atDistance: progress).coordinate
        let cut = route.distances.firstIndex { $0 > progress } ?? route.points.count
        let done = route.points[..<cut].map(\.coordinate) + [here]
        let ahead = [here] + route.points[cut...].map(\.coordinate)
        return (done, ahead)
    }
}

/// The rider on the ride map: an arrow pointing up the screen (the map turns
/// to the direction of travel), or a dot until there's a direction.
private struct RiderMarker: View {
    let hasHeading: Bool
    let offRoute: Bool

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.6)).frame(width: 40, height: 40)
            if hasHeading {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(offRoute ? Theme.warning : Color.white)
            } else {
                Circle().fill(offRoute ? Theme.warning : Color.white).frame(width: 18, height: 18)
            }
        }
        .accessibilityLabel("You")
    }
}

/// "RIGHT · 80 m" in the route's cyan, across the top of the map.
struct TurnBanner: View {
    let turn: RouteTurn
    let distance: Double?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: Self.symbol(turn.direction))
                .font(.system(size: 46, weight: .bold))
                .frame(width: 56)
            Text(turn.label)
                .font(.system(size: 40, weight: .heavy).width(.condensed))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Spacer(minLength: 6)
            if let distance {
                Text(Self.distanceText(distance))
                    .font(.system(size: 40, weight: .heavy).width(.condensed).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.route, in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(Color.black)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    /// To the nearest 10 m; "NOW" when there.
    static func distanceText(_ metres: Double) -> String {
        metres < 15 ? "NOW" : "\(Int((metres / 10).rounded()) * 10) m"
    }

    static func symbol(_ direction: RouteTurn.Direction) -> String {
        switch direction {
        case .slightLeft: return "arrow.up.left"
        case .left: return "arrow.turn.up.left"
        case .sharpLeft: return "arrow.down.left"
        case .slightRight: return "arrow.up.right"
        case .right: return "arrow.turn.up.right"
        case .sharpRight: return "arrow.down.right"
        case .uTurn: return "arrow.uturn.down"
        }
    }
}

/// "OFF ROUTE" in orange across the top of the map, until back within 30 m.
struct OffRouteBanner: View {
    let offset: Double?

    var body: some View {
        VStack(spacing: 2) {
            Text("OFF ROUTE")
                .font(.system(size: 46, weight: .heavy).width(.condensed))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let offset {
                Text("\(Int((offset / 10).rounded()) * 10) m from the route")
                    .font(.system(size: 18, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.warning, in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(Color.black)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}

extension RoutePoint {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
