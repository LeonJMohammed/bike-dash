import BikeDashCore
import Charts
import MapKit
import SwiftUI

/// One route: the line on a map, its distance and climb, the elevation profile,
/// and "Use for next ride" (which keeps the GPX on the phone).
struct RoutePreviewView: View {
    let library: RouteLibrary
    let ref: RouteRef

    private enum Load {
        case loading
        case ready(Route, gpx: Data?)
        case failed(String)
    }

    @State private var load: Load = .loading

    var body: some View {
        Group {
            switch load {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Getting the route from Strava…").foregroundStyle(Theme.dim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView("Couldn't open the route", systemImage: "map", description: Text(message))
            case .ready(let route, let gpx):
                ScrollView {
                    VStack(spacing: 0) {
                        RouteMap(route: route)
                            .frame(height: 340)
                        numbers(route)
                        HorizontalRule()
                        ElevationProfile(route: route)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        HorizontalRule()
                        useButton(route: route, gpx: gpx)
                            .padding(16)
                        Text("Without signal on the ride, the route line, your position and the warnings still work, but the map underneath may be blank: Apple doesn't let apps save maps ahead of time.")
                            .font(.footnote)
                            .foregroundStyle(Theme.dim)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ref) { await open() }
    }

    private var title: String {
        switch ref {
        case .strava(let route): return route.name
        case .saved(let saved): return saved.name
        }
    }

    private var id: String {
        switch ref {
        case .strava(let route): return route.id
        case .saved(let saved): return saved.id
        }
    }

    /// Strava's figures when there are any; the GPX's otherwise.
    private func figures(_ route: Route) -> (distance: Double, climb: Double) {
        switch ref {
        case .strava(let s):
            return (s.distance > 0 ? s.distance : route.length, s.elevationGain > 0 ? s.elevationGain : route.elevationGain)
        case .saved(let s):
            return (s.distance, s.elevationGain)
        }
    }

    private func numbers(_ route: Route) -> some View {
        let f = figures(route)
        return HStack(spacing: 0) {
            MetricTile(label: "DISTANCE", value: RideFormat.distance(f.distance), size: 44)
            VerticalRule()
            MetricTile(label: "CLIMB", value: RideFormat.metres(f.climb), size: 44)
        }
        .frame(height: 96)
    }

    @ViewBuilder
    private func useButton(route: Route, gpx: Data?) -> some View {
        if library.nextRideID == id {
            VStack(spacing: 10) {
                Label("Picked for the next ride", systemImage: "checkmark.circle.fill")
                    .font(Theme.barLabel)
                    .foregroundStyle(Theme.route)
                Button("Clear", role: .destructive) { library.clearNextRide() }
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        } else {
            Button {
                switch ref {
                case .strava(let stravaRoute):
                    if let gpx { library.useForNextRide(stravaRoute, gpx: gpx, route: route) }
                case .saved(let saved):
                    library.useForNextRide(saved)
                }
            } label: {
                Text("USE FOR NEXT RIDE")
                    .font(Theme.barLabel)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Capsule().fill(Theme.red))
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
        }
    }

    private func open() async {
        switch ref {
        case .saved(let saved):
            if let route = library.route(for: saved) {
                load = .ready(route, gpx: nil)
            } else {
                load = .failed("The saved copy is missing. Open it from the Strava list to download it again.")
            }
        case .strava(let stravaRoute):
            load = .loading
            do {
                let opened = try await library.open(stravaRoute)
                load = .ready(opened.route, gpx: opened.gpx)
            } catch let failure as RoutesService.Failure {
                load = .failed(failure.message)
            } catch {
                load = .failed(error.localizedDescription)
            }
        }
    }
}

/// The route line on a dark map, framed to fit, with start and finish marks.
struct RouteMap: View {
    let route: Route

    var body: some View {
        let coordinates = route.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        Map(initialPosition: .rect(Self.fit(route))) {
            MapPolyline(coordinates: coordinates)
                .stroke(Theme.route, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            if let start = coordinates.first {
                Annotation("Start", coordinate: start, anchor: .center) {
                    Circle().fill(Color.green)
                        .overlay(Circle().stroke(Color.black, lineWidth: 2))
                        .frame(width: 16, height: 16)
                }
            }
            if let finish = coordinates.last {
                Annotation("Finish", coordinate: finish, anchor: .bottomLeading) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black, radius: 2)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .environment(\.colorScheme, .dark)
    }

    /// The route's bounds with a margin.
    static func fit(_ route: Route) -> MKMapRect {
        let b = route.bounds
        let sw = MKMapPoint(CLLocationCoordinate2D(latitude: b.south, longitude: b.west))
        let ne = MKMapPoint(CLLocationCoordinate2D(latitude: b.north, longitude: b.east))
        let rect = MKMapRect(x: min(sw.x, ne.x), y: min(sw.y, ne.y), width: abs(ne.x - sw.x), height: abs(ne.y - sw.y))
        let margin = max(rect.width, rect.height) * 0.12 + 200
        return rect.insetBy(dx: -margin, dy: -margin)
    }
}

/// Elevation against distance, from the GPX.
struct ElevationProfile: View {
    let route: Route

    var body: some View {
        let profile = route.elevationProfile(samples: 160)
        VStack(alignment: .leading, spacing: 8) {
            Text("ELEVATION")
                .font(Theme.tileLabel)
                .foregroundStyle(Theme.dim)
            if profile.isEmpty {
                Text("This route has no elevation data.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.dim)
            } else {
                let low = profile.map(\.elevation).min() ?? 0
                let high = profile.map(\.elevation).max() ?? 0
                let floor = (low - max(5, (high - low) * 0.15)).rounded(.down)
                let ceiling = (high + max(5, (high - low) * 0.1)).rounded(.up)
                Chart(profile) { sample in
                    AreaMark(
                        x: .value("km", sample.distance / 1000),
                        yStart: .value("Floor", floor),
                        yEnd: .value("m", sample.elevation)
                    )
                    .foregroundStyle(Theme.route.opacity(0.25))
                    LineMark(x: .value("km", sample.distance / 1000), y: .value("m", sample.elevation))
                        .foregroundStyle(Theme.route)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: floor...ceiling)
                .chartXScale(domain: 0...(route.length / 1000))
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(Theme.divider)
                        AxisValueLabel { Text("\(value.as(Double.self).map { Self.km($0) } ?? "") km") }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Theme.divider)
                        AxisValueLabel { Text("\(value.as(Double.self).map { Int($0) } ?? 0) m") }
                    }
                }
                .frame(height: 130)
            }
        }
    }

    /// Axis kilometres: "2.5", "10".
    static func km(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
