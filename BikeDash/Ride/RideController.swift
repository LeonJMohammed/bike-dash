import AudioToolbox
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
/// GPS then runs only as a fallback, when the sensor drops out mid-ride, or
/// to follow a route picked for the ride (still not for speed or distance).
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
    /// The route picked for the next ride; it clears when that ride ends.
    let routes: RouteLibrary
    /// Following the picked route, while a ride with one is under way.
    private(set) var navigator: RouteNavigator?
    let dimmer = ScreenDimmer()
    let liveActivity = LiveActivityController()
    /// Bumped when a tap on the Live Activity asks for the ride screen, so any
    /// open sheet closes.
    private(set) var rideScreenRequests = 0
    /// The lit heart rate zone (0 below zone 1, up to 5), nil before a reading.
    private(set) var heartRateZone: Int?

    static let maxHeartRateKey = "maxHeartRate"
    /// The zones from the max heart rate in Settings.
    static var heartRateZones: HeartRateZones {
        HeartRateZones(maxHeartRate: UserDefaults.standard.object(forKey: maxHeartRateKey) as? Int ?? HeartRateZones.defaultMax)
    }

    @ObservationIgnored private var zoneTracker = ZoneTracker()

    /// The "Eat / Drink" banner is up.
    private(set) var reminderShowing = false
    /// The Settings switch (off to start) and interval in minutes (30 to start).
    private(set) var remindersOn: Bool
    private(set) var reminderInterval: Int
    @ObservationIgnored private var reminder = EatDrinkReminder()

    /// Auto lap every this many km, 0 for off (Settings; 5 to start).
    private(set) var autoLapKm: Int
    static let autoLapChoices = [0, 1, 2, 5, 10, 20]
    private static let autoLapKey = "autoLapKm"
    /// The lap whose numbers are on screen for a few seconds after it ends.
    private(set) var lapShowing: Lap?
    @ObservationIgnored private var lapShownAt: Date?
    @ObservationIgnored private var lapsSeen = 0
    private static let lapShowFor: TimeInterval = 5
    private static let remindersOnKey = "eatDrinkReminders"
    private static let reminderIntervalKey = "eatDrinkInterval"

    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastSavedAt = Date.distantPast
    @ObservationIgnored private var appIsActive = false
    /// In front and not covered (Control Center, a call), for dimming.
    @ObservationIgnored private var inFront = false
    /// When the sensor last took over as the speed source.
    @ObservationIgnored private var sensorSince = Date.distantPast
    private static let autoPauseKey = "autoPause"
    private static let speedSourceKey = "speedSource"

    init(
        heartRate: HeartRateService,
        sensors: CyclingSensorService,
        location: LocationService,
        altimeter: AltimeterService,
        history: RideHistory,
        routes: RouteLibrary
    ) {
        self.heartRate = heartRate
        self.sensors = sensors
        self.location = location
        self.altimeter = altimeter
        self.history = history
        self.routes = routes
        let autoPause = UserDefaults.standard.object(forKey: Self.autoPauseKey) as? Bool ?? true
        self.autoPause = autoPause
        let defaults = UserDefaults.standard
        remindersOn = defaults.object(forKey: Self.remindersOnKey) != nil && defaults.bool(forKey: Self.remindersOnKey)
        let interval = defaults.integer(forKey: Self.reminderIntervalKey)
        reminderInterval = EatDrinkReminder.intervalChoices.contains(interval) ? interval : EatDrinkReminder.defaultInterval
        let lapKm = defaults.object(forKey: Self.autoLapKey) == nil ? 5 : defaults.integer(forKey: Self.autoLapKey)
        let autoLapKm = Self.autoLapChoices.contains(lapKm) ? lapKm : 5
        self.autoLapKm = autoLapKm
        let preference = UserDefaults.standard.string(forKey: Self.speedSourceKey)
            .flatMap(SpeedSourcePicker.Preference.init(rawValue:)) ?? .sensor
        let picker = SpeedSourcePicker(preference: preference)
        self.picker = picker
        session = RideSession(settings: Self.sessionSettings(autoPause: autoPause, source: picker.source, autoLapKm: autoLapKm))
        location.onFix = { [weak self] fix in
            self?.gotFix(fix)
        }
        sensors.onUpdate = { [weak self] update in
            self?.feedSensors(update)
        }
        heartRate.onReading = { [weak self] bpm in
            self?.gotHeartRate(bpm)
        }
        altimeter.onAltitude = { [weak self] metres in
            self?.session.addAltitude(metres)
        }
        restore()
        if !session.isActive {
            liveActivity.endAll()
        }
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
        session.batteryAtStart = Battery.percent()
        session.start(at: time)
        // Before the speed source is picked, so GPS starts for the route.
        startNavigation()
        refreshSource(at: time)
        startTicker()
        updateScreenLock()
        dimmer.wake(at: Date())
        reminder.restart(movingTime: 0)
        reminderShowing = false
        lapsSeen = 0
        dismissLap()
        liveActivity.start(activityState(at: Date()), startedAt: time)
        save()
    }

    func pause() {
        session.pause(at: Date())
        refreshSource(at: Date())
        updateLiveActivity(at: Date())
        save()
    }

    func resume() {
        session.resume(at: Date())
        refreshSource(at: Date())
        updateLiveActivity(at: Date())
        save()
    }

    func finish() {
        session.batteryAtEnd = Battery.percent()
        session.finish(at: Date())
        altimeter.stop()
        stopTicker()
        dimmer.restore()
        reminder.restart(movingTime: 0)
        reminderShowing = false
        // The final lap goes into the summary, not on screen.
        lapsSeen = session.laps.count
        dismissLap()
        liveActivity.end(activityState(at: Date()))
        refreshSource(at: Date())
        if let record = session.record() {
            history.add(record)
        }
        // A route was for this ride only (Leon's choice): the next is a normal ride.
        routes.rideFinished()
        navigator = nil
        updateGPS()
        updateScreenLock()
        save()
    }

    /// Clears the summary for the next ride.
    func newRide() {
        navigator = nil
        session = RideSession(settings: Self.sessionSettings(autoPause: autoPause, source: picker.source, autoLapKm: autoLapKm))
        lapsSeen = 0
        dismissLap()
        deleteSave()
        updateScreenLock()
    }

    func setAutoPause(_ on: Bool) {
        autoPause = on
        UserDefaults.standard.set(on, forKey: Self.autoPauseKey)
        session.settings = Self.sessionSettings(autoPause: on, source: picker.source, autoLapKm: autoLapKm)
    }

    func setAutoLapKm(_ km: Int) {
        guard Self.autoLapChoices.contains(km) else { return }
        autoLapKm = km
        UserDefaults.standard.set(km, forKey: Self.autoLapKey)
        session.settings = Self.sessionSettings(autoPause: autoPause, source: picker.source, autoLapKm: km)
    }

    /// The LAP button: ends the lap under way and shows it.
    func lap() {
        session.lap(at: Date())
        showNewLaps()
        save()
    }

    /// A tap on the lap summary: back to the ride numbers early.
    func dismissLap() {
        lapShowing = nil
        lapShownAt = nil
    }

    func setRemindersOn(_ on: Bool) {
        remindersOn = on
        UserDefaults.standard.set(on, forKey: Self.remindersOnKey)
        // Switched on mid-ride: the first reminder is a full interval away.
        restartReminder()
    }

    func setReminderInterval(_ minutes: Int) {
        guard EatDrinkReminder.intervalChoices.contains(minutes) else { return }
        reminderInterval = minutes
        UserDefaults.standard.set(minutes, forKey: Self.reminderIntervalKey)
    }

    /// A tap on the "Eat / Drink" banner.
    func dismissReminder() {
        reminder.dismiss(movingTime: session.movingTime(at: Date()))
        reminderShowing = false
    }

    /// Minutes of moving time to the next reminder, while one is counting down.
    func minutesToReminder(at now: Date) -> Int? {
        guard remindersOn, session.isActive, !reminderShowing else { return nil }
        let seconds = reminder.remaining(movingTime: session.movingTime(at: now), intervalMinutes: reminderInterval)
        return Int((seconds / 60).rounded(.up))
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

    /// Demo mode only: cadence samples for a replayed ride's laps.
    func addDemoCadence(_ rpm: Double) {
        session.addCadence(rpm)
    }

    /// A touch anywhere, or something worth seeing (a lap, a reminder, a heart
    /// rate zone change): brighten a dimmed screen, and dim again 10 s later.
    func wakeScreen() {
        dimmer.wake(at: Date())
    }

    /// A tap on the Live Activity: the ride screen, with any sheet closed.
    func showRideScreen() {
        rideScreenRequests += 1
    }

    // MARK: - Route

    /// The route on screen: the one being followed, or before a ride the one
    /// picked for it. Nil means the normal ride screen.
    var mapRoute: Route? {
        if let navigator { return navigator.route }
        guard session.state == .idle, let saved = routes.nextRide else { return nil }
        return routes.route(for: saved)
    }

    /// A ride is starting (or being picked up again) with a route picked.
    private func startNavigation() {
        guard let saved = routes.nextRide, let route = routes.route(for: saved) else {
            navigator = nil
            return
        }
        navigator = RouteNavigator(saved: saved, route: route)
        session.routeName = saved.name
    }

    /// A turn ahead: one buzz. Off the route: a buzz and the chime. Either
    /// brightens a dimmed screen and takes a lap summary away.
    private func handle(_ events: [RouteNavigator.Event]) {
        for event in events {
            switch event {
            case .turn:
                dismissLap()
                wakeScreen()
                if !DemoMode.isOn { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
            case .offRoute:
                dismissLap()
                wakeScreen()
                if !DemoMode.isOn {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    AudioServicesPlaySystemSound(1007)  // the tri-tone; silent with the ringer off
                }
            case .backOnRoute:
                break
            }
        }
    }

    /// The ride's numbers for the Live Activity.
    private func activityState(at now: Date) -> RideActivityState {
        RideActivityState(
            session: session,
            speed: speed(at: now),
            heartRate: heartRate.bpm(at: now),
            cadence: sensors.cadence(at: now),
            at: now
        )
    }

    /// Called often (ticks, sensor packets, fixes, heart rate) so the Live
    /// Activity keeps up while the phone is locked; the throttle decides.
    private func updateLiveActivity(at now: Date) {
        guard session.isActive else { return }
        liveActivity.update(activityState(at: now), at: now)
    }

    /// Once a second: puts the "Eat / Drink" banner up when it's due (with a
    /// buzz, a chime and a bright screen) and takes it down after 15 s.
    private func updateReminder(at now: Date) {
        let change = reminder.update(
            movingTime: session.movingTime(at: now),
            intervalMinutes: reminderInterval,
            enabled: remindersOn && session.isActive,
            now: now
        )
        switch change {
        case .show:
            reminderShowing = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            AudioServicesPlaySystemSound(1007)  // the tri-tone; silent with the ringer off
        case .hide:
            reminderShowing = false
        case nil:
            break
        }
        // Keep the screen bright while the banner is up.
        if reminderShowing { dimmer.wake(at: now) }
    }

    private func restartReminder() {
        reminder.restart(movingTime: session.movingTime(at: Date()))
        reminderShowing = false
    }

    /// Each heart rate reading: a new zone is worth a look.
    private func gotHeartRate(_ bpm: Int) {
        guard bpm > 0 else { return }
        if zoneTracker.update(bpm: bpm, zones: Self.heartRateZones) {
            wakeScreen()
        }
        if heartRateZone != zoneTracker.zone {
            heartRateZone = zoneTracker.zone
        }
        updateLiveActivity(at: Date())
    }

    // MARK: - App lifecycle

    func appBecameActive() {
        appIsActive = true
        inFront = true
        dimmer.wake(at: Date())
        // GPS asked for while in the background may not have started.
        location.ensureRunning()
        refreshSource(at: Date())
        updateScreenLock()
    }

    /// Covered by Control Center, a call or the app switcher: normal brightness.
    func appBecameInactive() {
        inFront = false
        dimmer.restore()
    }

    func appWentToBackground() {
        appIsActive = false
        inFront = false
        dimmer.restore()
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
            session.settings = Self.sessionSettings(autoPause: autoPause, source: picker.source, autoLapKm: autoLapKm)
        }
        updateGPS()
    }

    /// GPS runs only when it's the source: as the chosen source while the app
    /// is open or a ride is under way, or as the fallback. And while a ride
    /// with a route is under way, for the map and the warnings.
    private func updateGPS() {
        let wanted: Bool
        switch picker.source {
        case .sensor: wanted = navigator != nil && session.isActive
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
        if session.isActive, let navigator {
            handle(navigator.add(fix, riding: session.state == .riding))
        }
        // With the sensor in use, GPS is only for the route.
        guard picker.source != .sensor else { return }
        session.add(fix)
        showNewLaps()
        updateLiveActivity(at: Date())
    }

    /// A sensor packet, a connection change or a tick: picks the source, then
    /// feeds the wheel sensor's distance and speed to the ride if it's in use.
    private func feedSensors(_ update: CyclingSensorService.Update) {
        refreshSource(at: update.at)
        defer { updateLiveActivity(at: Date()) }
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
        showNewLaps()
    }

    private static func sessionSettings(autoPause: Bool, source: SpeedSourcePicker.Source, autoLapKm: Int) -> RideSession.Settings {
        var settings: RideSession.Settings = source == .sensor ? .wheelSensor(autoPause: autoPause) : .gps(autoPause: autoPause)
        settings.autoLapDistance = autoLapKm > 0 ? Double(autoLapKm) * 1000 : nil
        return settings
    }

    /// A lap that just ended (auto or LAP): show its numbers for 5 seconds and
    /// brighten a dimmed screen. Laps from a ride being picked up again, or
    /// replayed in demo mode, are only counted.
    private func showNewLaps() {
        guard session.laps.count > lapsSeen else { return }
        lapsSeen = session.laps.count
        guard session.isActive, let lap = session.laps.last,
              Date().timeIntervalSince(lap.endedAt) < Self.lapShowFor else { return }
        lapShowing = lap
        lapShownAt = Date()
        wakeScreen()
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
        // One cadence sample a second for the lap averages (0 while coasting doesn't count).
        if let rpm = sensors.cadence(at: now) {
            session.addCadence(rpm)
        }
        // The wheel's speed drops to 0 with no packets at all, so check every second.
        feedSensors(CyclingSensorService.Update(at: now))
        if let lapShownAt, now.timeIntervalSince(lapShownAt) >= Self.lapShowFor {
            dismissLap()
        }
        updateReminder(at: now)
        // Keep the screen bright while a turn is coming up.
        if navigator?.turn != nil { dimmer.wake(at: now) }
        dimmer.update(at: now, rideActive: session.isActive, appActive: inFront)
        updateLiveActivity(at: now)
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
        session = RideSession(restoring: snapshot, settings: Self.sessionSettings(autoPause: autoPause, source: picker.source, autoLapKm: autoLapKm))
        log.info("Restored a ride in state \(String(describing: snapshot.state), privacy: .public)")
        lapsSeen = session.laps.count
        if session.isActive {
            session.resetAltitudeReference()
            altimeter.start()
            // The route is still picked (it clears when the ride ends).
            startNavigation()
            startTicker()
            // The countdown isn't saved: a full interval from here.
            restartReminder()
            liveActivity.resume(activityState(at: Date()), startedAt: session.startedAt ?? Date())
        }
        refreshSource(at: Date())
        // The screen lock is set in appBecameActive(): this runs during launch.
    }
}
