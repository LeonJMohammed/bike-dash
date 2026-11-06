import CoreMotion
import Foundation

/// The barometer, for the ascent figure. Runs only during a ride.
@MainActor
final class AltimeterService {
    /// Relative altitude in metres; starts from 0 each time updates start.
    var onAltitude: (@MainActor (Double) -> Void)?
    private let altimeter = CMAltimeter()
    private(set) var isRunning = false

    func start() {
        guard !isRunning, !DemoMode.isOn, CMAltimeter.isRelativeAltitudeAvailable() else { return }
        isRunning = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let metres = data?.relativeAltitude.doubleValue else { return }
            MainActor.assumeIsolated {
                self?.onAltitude?(metres)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        altimeter.stopRelativeAltitudeUpdates()
        isRunning = false
    }
}
