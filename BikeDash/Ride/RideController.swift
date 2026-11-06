import BikeDashCore
import Foundation
import Observation
import os
import UIKit

private let log = Logger(subsystem: "com.jlmoh.bikedash", category: "ride")

/// Runs the ride: feeds GPS and heart rate into the RideSession, keeps the
/// screen on, and saves the ride every 10 s so it survives the app closing.
@MainActor
@Observable
final class RideController {
    private(set) var session = RideSession()
    let heartRate: HeartRateService
    let location: LocationService

    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastSavedAt = Date.distantPast

    init(heartRate: HeartRateService, location: LocationService) {
        self.heartRate = heartRate
        self.location = location
        location.onFix = { [weak self] fix in
            self?.session.add(fix)
        }
        restore()
    }

    // MARK: - Controls

    func start() {
        location.start()
        session.start(at: Date())
        startTicker()
        updateScreenLock()
        save()
    }

    func pause() {
        session.pause(at: Date())
        save()
    }

    func resume() {
        session.resume(at: Date())
        save()
    }

    func finish() {
        session.finish(at: Date())
        stopTicker()
        updateScreenLock()
        save()
    }

    /// Clears the summary for the next ride.
    func newRide() {
        session.reset()
        deleteSave()
        updateScreenLock()
    }

    // MARK: - App lifecycle

    /// Warms GPS up while the app is open, so the speed is ready before Start.
    func appBecameActive() {
        location.start()
        updateScreenLock()
    }

    /// Keeps GPS on in the background only while a ride is under way.
    func appWentToBackground() {
        if !session.isActive {
            location.stop()
        }
    }

    // MARK: - Private

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        let now = Date()
        if let bpm = heartRate.bpm(at: now) {
            session.addHeartRate(bpm)
        }
        if now.timeIntervalSince(lastSavedAt) >= 10 {
            save()
        }
    }

    private func updateScreenLock() {
        UIApplication.shared.isIdleTimerDisabled = session.isActive
    }

    private var saveURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ride.json")
    }

    private func save() {
        lastSavedAt = Date()
        do {
            try FileManager.default.createDirectory(
                at: saveURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(session.snapshot).write(to: saveURL, options: .atomic)
        } catch {
            log.error("Couldn't save the ride: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deleteSave() {
        try? FileManager.default.removeItem(at: saveURL)
    }

    /// Picks up a ride (or a finished ride's summary) saved before the app closed.
    private func restore() {
        guard let data = try? Data(contentsOf: saveURL),
              let snapshot = try? JSONDecoder().decode(RideSession.Snapshot.self, from: data) else { return }
        session = RideSession(restoring: snapshot)
        log.info("Restored a ride in state \(String(describing: snapshot.state), privacy: .public)")
        if session.isActive {
            location.start()
            startTicker()
        }
        // The screen lock is set in appBecameActive(): this runs during launch.
    }
}
