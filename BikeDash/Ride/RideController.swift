import BikeDashCore
import Foundation
import Observation
import os
import UIKit

private let log = Logger(subsystem: "com.jlmoh.bikedash", category: "ride")

/// Runs the ride: feeds the wheel sensor (or GPS), heart rate and the barometer
/// into the RideSession, keeps the screen on, saves the ride every 10 s so it
/// survives the app closing, and adds finished rides to the history.
///
/// Speed and distance come from the speed sensor unless Settings says GPS.
/// GPS then runs only as a fallback, when the sensor drops out mid-ride.
@MainActor
@Observable
final class RideController {
    private(set) var session: RideSession
    /// The Settings switch; it also applies to a ride under way.
    private(set) var autoPause: Bool
    private(set) var picker: SpeedSourcePicker
    let heartRate: HeartRateService
    let sensors: CyclingSensorService
    let location: LocationService
    let altimeter: AltimeterService
    let history: RideHistory

    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastSavedAt = Date.distantPast
    @ObservationIgnored private var appIsActive = false
    /// When the sensor last took over as the speed source.
    @ObservationIgnored private var sensorSince = Date.distantPast
    private static let autoPauseKey = "autoPause"
    private static let speedSourceKey = "speedSource"

    init(
        heartRate: HeartRateService,
        sensors: CyclingSensorService,
        location: LocationService,
        altimeter: AltimeterService,
        history: RideHistory
    ) {
        self.heartRate = heartRate
        self.sensors = sensors
        self.location = location
        self.altimeter = altimeter
        self.history = history
        let autoPause = UserDefaults.standard.object(forKey: Self.autoPauseKey) as? Bool ?? true
        self.autoPause = autoPause
        let preference = UserDefaults.standard.string(forKey: Self.speedSourceKey)
            .flatMap(SpeedSourcePicker.Preference.init(rawValue:)) ?? .sensor
        let picker = SpeedSourcePicker(preference: preference)
        self.picker = picker
        session = RideSession(settings: Self.pauseRules(autoPause: autoPause, source: picker.source))
        location.onFix = { [weak self] fix in
            self?.gotFix(fix)
        }
        sensors.onUpdate = { [weak self] update in
            self?.feedSensors(update)
        }
        altimeter.onAltitude = { [weak self] metres in
            self?.session.addAltitude(metres)
        }
        restore()
    }

    // MARK: - Readings

    var speedSource: SpeedSourcePicker.Source { picker.source }
    var speedPreference: SpeedSourcePicker.Preference { picker.preference }

    /// The speed on screen, m/s: from the wheel sensor or GPS, whichever is in use.
    func speed(at now: Date) -> Double? {
        picker.source == .sensor ? sensors.speed(at: now) : session.speed(at: now)
    }

    // MARK: - Controls

    func start(at time: Date = Date()) {
        session.resetAltitudeReference()
        altimeter.start()
        session.start(at: time)
        refreshSource(at: time)
        startTicker()
        updateScreenLock()
        save()
    }

    func pause() {
        session.pause(at: Date())
        refreshSource(at: Date())
        save()
    }

    func resume() {
        session.resume(at: Date())
        refreshSource(at: Date())
        save()
    }

    func finish() {
        session.finish(at: Date())
        altimeter.stop()
        stopTicker()
        refreshSource(at: Date())
        if let record = session.record() {
            history.add(record)
        }
        updateScreenLock()
        save()
    }

    /// Clears the summary for the next ride.
    func newRide() {
        session = RideSession(settings: Self.pauseRules(autoPause: autoPause, source: picker.source))
        deleteSave()
        updateScreenLock()
    }

    func setAutoPause(_ on: Bool) {
        autoPause = on
        UserDefaults.standard.set(on, forKey: Self.autoPauseKey)
        session.settings = Self.pauseRules(autoPause: on, source: picker.source)
    }

    func setSpeedPreference(_ preference: SpeedSourcePicker.Preference) {
        UserDefaults.standard.set(preference.rawValue, forKey: Self.speedSourceKey)
        picker.preference = preference
        refreshSource(at: Date())
    }

    /// Demo mode only: heart rate samples for a replayed ride.
    func addDemoHeartRate(_ bpm: Int) {
        session.addHeartRate(bpm)
    }

    // MARK: - App lifecycle

    func appBecameActive() {
        appIsActive = true
        // GPS asked for while in the background may not have started.
        location.ensureRunning()
        refreshSource(at: Date())
        updateScreenLock()
    }

    func appWentToBackground() {
        appIsActive = false
        refreshSource(at: Date())
    }

    // MARK: - Speed source

    /// Picks the speed source again (on every tick, sensor packet and ride
    /// control), and switches GPS on or off to match.
    private func refreshSource(at now: Date) {
        let pedalling = (sensors.cadence(at: now) ?? 0) > 0
        if picker.update(sensorConnected: sensors.isConnected(.speed), ride: session.state, pedalling: pedalling, at: now) {
            log.info("Speed now comes from \(String(describing: self.picker.source), privacy: .public)")
            // The next GPS fix starts a new segment, so the gap isn't counted twice.
            session.breakGPSTrack()
            if picker.source == .sensor { sensorSince = now }
            session.settings = Self.pauseRules(autoPause: autoPause, source: picker.source)
        }
        updateGPS()
    }

    /// GPS runs only when it's the source: as the chosen source while the app
    /// is open or a ride is under way, or as the fallback.
    private func updateGPS() {
        let wanted: Bool
        switch picker.source {
        case .sensor: wanted = false
        case .gps: wanted = appIsActive || session.isActive
        case .gpsFallback: wanted = true
        }
        if wanted, !location.isRequested, location.permission != .denied {
            location.start()
        } else if !wanted, location.isRequested {
            location.stop()
        }
    }

    private func gotFix(_ fix: GPSFix) {
        guard picker.source != .sensor else { return }
        session.add(fix)
    }

    /// A sensor packet, a connection change or a tick: picks the source, then
    /// feeds the wheel sensor's distance and speed to the ride if it's in use.
    private func feedSensors(_ update: CyclingSensorService.Update) {
        refreshSource(at: update.at)
        guard picker.source == .sensor else { return }
        if let stoppedSince = update.wheelStoppedSince {
            // The wheel stood still until this packet. If the ride didn't pause
            // in time (the app was asleep in the background), it pauses from then.
            session.addMovement(distance: 0, speed: 0, at: update.at, stillSince: max(stoppedSince, sensorSince))
        }
        var metres = 0.0
        // Only revolutions between two packets that both came after the sensor
        // took over: before that, GPS was counting.
        if update.wheelRevolutions > 0, let since = update.wheelSince, since >= sensorSince {
            metres = Double(update.wheelRevolutions) * sensors.circumferenceMetres
        }
        let stillSince = sensors.wheelLastTurnedAt.map { max($0, sensorSince) }
        session.addMovement(distance: metres, speed: sensors.speed(at: update.at), at: update.at, stillSince: stillSince)
    }

    private static func pauseRules(autoPause: Bool, source: SpeedSourcePicker.Source) -> RideSession.Settings {
        source == .sensor ? .wheelSensor(autoPause: autoPause) : .gps(autoPause: autoPause)
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
        // The wheel's speed drops to 0 with no packets at all, so check every second.
        feedSensors(CyclingSensorService.Update(at: now))
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
        guard !DemoMode.isOn else { return }
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
        guard !DemoMode.isOn,
              let data = try? Data(contentsOf: saveURL),
              let snapshot = try? JSONDecoder().decode(RideSession.Snapshot.self, from: data) else { return }
        session = RideSession(restoring: snapshot, settings: Self.pauseRules(autoPause: autoPause, source: picker.source))
        log.info("Restored a ride in state \(String(describing: snapshot.state), privacy: .public)")
        if session.isActive {
            session.resetAltitudeReference()
            altimeter.start()
            startTicker()
        }
        refreshSource(at: Date())
        // The screen lock is set in appBecameActive(): this runs during launch.
    }
}
