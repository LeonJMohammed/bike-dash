import BikeDashCore
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.jlmoh.bikedash", category: "routes")

/// A route kept on the phone: its GPX is in Application Support/routes/<id>.gpx,
/// so it opens without signal.
struct SavedRoute: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var kind: StravaRoute.Kind
    /// Metres, and metres climbed (Strava's figures when it had them).
    var distance: Double
    var elevationGain: Double
    /// Strava's `updated_at` when it was saved, to spot a newer version.
    var stravaUpdatedAt: String?
    var savedAt: Date
}

/// Your Strava routes (listed by the home PC), the ones saved on this phone,
/// and the one picked for the next ride, which clears when that ride ends.
@MainActor
@Observable
final class RouteLibrary {
    enum ListState: Equatable {
        case idle, loading, loaded
        case failed(RoutesService.Failure)
        case notSetUp
    }

    private(set) var strava: [StravaRoute] = []
    private(set) var privateHidden = false
    private(set) var listState: ListState = .idle
    private(set) var saved: [SavedRoute] = []
    private(set) var nextRideID: String?

    static let nextRideKey = "nextRideRoute"
    @ObservationIgnored private var parsed: [String: Route] = [:]
    /// Demo mode keeps its GPX here instead of on disk.
    @ObservationIgnored private var demoFiles: [String: Data] = [:]
    private let service = RoutesService.configured

    init() {
        guard !DemoMode.isOn else { return }
        loadIndex()
        nextRideID = UserDefaults.standard.string(forKey: Self.nextRideKey)
        if let id = nextRideID, !saved.contains(where: { $0.id == id }) {
            setNextRide(nil)
        }
    }

    /// The route picked for the next ride (or the ride under way).
    var nextRide: SavedRoute? {
        nextRideID.flatMap { id in saved.first { $0.id == id } }
    }

    func savedRoute(id: String) -> SavedRoute? {
        saved.first { $0.id == id }
    }

    // MARK: - Strava list

    func refresh() async {
        guard !DemoMode.isOn else { return }
        guard let service else {
            listState = .notSetUp
            return
        }
        listState = .loading
        do {
            let list = try await service.list()
            strava = list.routes
            privateHidden = list.privateHidden
            listState = .loaded
        } catch let failure as RoutesService.Failure {
            listState = .failed(failure)
        } catch {
            listState = .failed(.offline)
        }
    }

    // MARK: - Opening and saving routes

    /// The route to preview: the copy on the phone when it's current (works
    /// without signal), otherwise downloaded. Returns the parsed route and its
    /// GPX, for `save`.
    func open(_ route: StravaRoute) async throws -> (route: Route, gpx: Data) {
        if let copy = savedRoute(id: route.id), copy.stravaUpdatedAt == route.updatedAt,
           let data = gpxData(id: route.id), let parsed = parse(id: route.id, data: data, name: route.name) {
            return (parsed, data)
        }
        guard let service else { throw RoutesService.Failure.server("not_set_up") }
        let data = try await service.gpx(id: route.id)
        let parsedRoute: Route
        do {
            parsedRoute = try Route.parseGPX(data, fallbackName: route.name)
        } catch {
            throw RoutesService.Failure.server("not_gpx")
        }
        return (parsedRoute, data)
    }

    /// A saved route, parsed (from memory after the first time).
    func route(for saved: SavedRoute) -> Route? {
        if let route = parsed[saved.id] { return route }
        guard let data = gpxData(id: saved.id) else { return nil }
        return parse(id: saved.id, data: data, name: saved.name)
    }

    /// Keeps the GPX on the phone and picks the route for the next ride.
    func useForNextRide(_ stravaRoute: StravaRoute, gpx: Data, route: Route) {
        let entry = SavedRoute(
            id: stravaRoute.id,
            name: stravaRoute.name,
            kind: stravaRoute.kind,
            distance: stravaRoute.distance > 0 ? stravaRoute.distance : route.length,
            elevationGain: stravaRoute.elevationGain > 0 ? stravaRoute.elevationGain : route.elevationGain,
            stravaUpdatedAt: stravaRoute.updatedAt,
            savedAt: Date()
        )
        guard writeGPX(gpx, id: entry.id) else { return }
        parsed[entry.id] = route
        saved.removeAll { $0.id == entry.id }
        saved.insert(entry, at: 0)
        saveIndex()
        setNextRide(entry.id)
    }

    /// Picks a route already on the phone for the next ride.
    func useForNextRide(_ saved: SavedRoute) {
        setNextRide(saved.id)
    }

    func clearNextRide() {
        setNextRide(nil)
    }

    /// The ride with the route has ended: the next ride is a normal one again
    /// (Leon's choice). The route stays saved on the phone.
    func rideFinished() {
        setNextRide(nil)
    }

    func delete(_ route: SavedRoute) {
        saved.removeAll { $0.id == route.id }
        parsed[route.id] = nil
        if nextRideID == route.id { setNextRide(nil) }
        if DemoMode.isOn {
            demoFiles[route.id] = nil
        } else {
            try? FileManager.default.removeItem(at: gpxURL(id: route.id))
            saveIndex()
        }
    }

    // MARK: - Demo

    /// Simulator screenshots: a few listed routes, one saved (and picked, unless
    /// the scene is a normal ride).
    func loadDemo(strava: [StravaRoute], saved demo: StravaRoute, gpx: Data, pick: Bool) {
        self.strava = strava
        privateHidden = false
        listState = .loaded
        if let route = try? Route.parseGPX(gpx, fallbackName: demo.name) {
            demoFiles[demo.id] = gpx
            useForNextRide(demo, gpx: gpx, route: route)
            if !pick { setNextRide(nil) }
        }
    }

    // MARK: - Files

    private func setNextRide(_ id: String?) {
        nextRideID = id
        guard !DemoMode.isOn else { return }
        UserDefaults.standard.set(id, forKey: Self.nextRideKey)
    }

    private func parse(id: String, data: Data, name: String) -> Route? {
        guard let route = try? Route.parseGPX(data, fallbackName: name) else { return nil }
        parsed[id] = route
        return route
    }

    private var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("routes", isDirectory: true)
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    /// Route ids are digits only (the service checks), so they're safe file names.
    private func gpxURL(id: String) -> URL {
        folder.appendingPathComponent("\(id.filter(\.isNumber)).gpx")
    }

    private func gpxData(id: String) -> Data? {
        if DemoMode.isOn { return demoFiles[id] }
        return try? Data(contentsOf: gpxURL(id: id))
    }

    private func writeGPX(_ data: Data, id: String) -> Bool {
        if DemoMode.isOn {
            demoFiles[id] = data
            return true
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: gpxURL(id: id), options: .atomic)
            return true
        } catch {
            log.error("Couldn't save the route: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder().decode([SavedRoute].self, from: data) else { return }
        // Only entries whose GPX is still there.
        saved = entries.filter { FileManager.default.fileExists(atPath: gpxURL(id: $0.id).path) }
    }

    private func saveIndex() {
        guard !DemoMode.isOn else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: indexURL, options: .atomic)
        } catch {
            log.error("Couldn't save the route list: \(error.localizedDescription, privacy: .public)")
        }
    }
}
