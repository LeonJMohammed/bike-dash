import BikeDashCore
import SwiftUI

/// What a route row opens: a Strava route (downloaded unless the phone has the
/// current version) or one already saved on the phone.
enum RouteRef: Hashable {
    case strava(StravaRoute)
    case saved(SavedRoute)
}

/// The Routes sheet (the map button next to History, before a ride): the route
/// picked for the next ride, routes saved on the phone, and your Strava routes.
struct RoutesView: View {
    let library: RouteLibrary
    @Environment(\.dismiss) private var dismiss
    /// `-page routePreview` opens the next ride's route at launch (simulator screenshots).
    @State private var path: [RouteRef] = []
    @State private var openedDemoPage = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                nextRideSection
                savedSection
                stravaSections
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Routes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: RouteRef.self) { ref in
                RoutePreviewView(library: library, ref: ref)
            }
            .refreshable { await library.refresh() }
            .task {
                if library.listState == .idle { await library.refresh() }
            }
            .onChange(of: library.nextRideID, initial: true) {
                // Demo mode may pick its route just after the sheet opens.
                guard !openedDemoPage, UserDefaults.standard.string(forKey: "page") == "routePreview",
                      let next = library.nextRide else { return }
                openedDemoPage = true
                path = [.saved(next)]
            }
        }
    }

    @ViewBuilder private var nextRideSection: some View {
        Section {
            if let next = library.nextRide {
                NavigationLink(value: RouteRef.saved(next)) {
                    RouteRow(name: next.name, kind: next.kind, distance: next.distance,
                             elevationGain: next.elevationGain, detail: "Picked for the next ride",
                             highlighted: true)
                }
                Button("Clear", role: .destructive) { library.clearNextRide() }
            } else {
                Text("None: the next ride is a normal ride, with GPS off.")
                    .foregroundStyle(Theme.dim)
            }
        } header: {
            Text("Next ride")
        } footer: {
            Text("A route clears when the ride with it ends.")
        }
    }

    @ViewBuilder private var savedSection: some View {
        let others = library.saved.filter { $0.id != library.nextRideID }
        if !others.isEmpty {
            Section {
                ForEach(others) { saved in
                    NavigationLink(value: RouteRef.saved(saved)) {
                        RouteRow(name: saved.name, kind: saved.kind, distance: saved.distance,
                                 elevationGain: saved.elevationGain,
                                 detail: "Saved " + saved.savedAt.formatted(.dateTime.day().month(.abbreviated)))
                    }
                }
                .onDelete { offsets in
                    for index in offsets { library.delete(others[index]) }
                }
            } header: {
                Text("On this phone")
            } footer: {
                Text("Saved routes open without signal. Swipe to remove one.")
            }
        }
    }

    @ViewBuilder private var stravaSections: some View {
        let rides = library.strava.filter { $0.kind == .ride }
        let others = library.strava.filter { $0.kind != .ride }
        Section {
            switch library.listState {
            case .idle, .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Asking Strava…").foregroundStyle(Theme.dim)
                }
            case .notSetUp:
                Text("Routes aren't set up in this build (no routes key).")
                    .foregroundStyle(Theme.dim)
            case .failed(let failure):
                Label(failure.message, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(Theme.warning)
            case .loaded:
                if rides.isEmpty {
                    Text("No bike routes on Strava yet. Make one in Strava (Maps › Create route), then pull down to refresh.")
                        .foregroundStyle(Theme.dim)
                }
                ForEach(rides) { route in stravaRow(route) }
            }
        } header: {
            Text("Strava bike routes")
        } footer: {
            if library.privateHidden {
                Text("Private routes are hidden: Strava's read_all permission is missing in Race Tracker.")
            }
        }
        if library.listState == .loaded, !others.isEmpty {
            Section("Strava run routes") {
                ForEach(others) { route in stravaRow(route) }
            }
        }
    }

    private func stravaRow(_ route: StravaRoute) -> some View {
        NavigationLink(value: RouteRef.strava(route)) {
            RouteRow(name: route.name, kind: route.kind, distance: route.distance,
                     elevationGain: route.elevationGain, detail: detail(route),
                     highlighted: route.id == library.nextRideID)
        }
    }

    private func detail(_ route: StravaRoute) -> String {
        var parts: [String] = []
        if route.isPrivate { parts.append("Private") }
        if let updated = route.updated {
            parts.append("Updated " + updated.formatted(.dateTime.day().month(.abbreviated).year()))
        }
        if library.savedRoute(id: route.id) != nil { parts.append("On this phone") }
        return parts.joined(separator: " · ")
    }
}

/// Name, distance and climb, with a line of detail.
struct RouteRow: View {
    let name: String
    let kind: StravaRoute.Kind
    let distance: Double
    let elevationGain: Double
    let detail: String
    var highlighted = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind == .run ? "figure.run" : "bicycle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(highlighted ? Theme.route : Theme.dim)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                Text("\(RideFormat.distance(distance)) km · \(RideFormat.metres(elevationGain)) m up" + (detail.isEmpty ? "" : " · " + detail))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.vertical, 3)
    }
}
