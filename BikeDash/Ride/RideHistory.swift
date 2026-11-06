import BikeDashCore
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.jlmoh.bikedash", category: "history")

/// Finished rides, newest first, kept in Application Support/rides.json.
@MainActor
@Observable
final class RideHistory {
    private(set) var rides: [RideRecord] = []

    init() {
        load()
    }

    func add(_ record: RideRecord) {
        rides.append(record)
        rides.sort { $0.startedAt > $1.startedAt }
        save()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            rides.remove(at: index)
        }
        save()
    }

    private var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rides.json")
    }

    private func load() {
        guard !DemoMode.isOn,
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([RideRecord].self, from: data) else { return }
        rides = saved
    }

    private func save() {
        guard !DemoMode.isOn else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(rides).write(to: url, options: .atomic)
        } catch {
            log.error("Couldn't save the history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
