import BikeDashCore
import SwiftUI

/// A thin strip of the five heart rate zones along the bottom of the ride
/// screen: the current zone lit, the others dimmed, and a small white marker
/// where the heart rate sits inside that zone. No numbers. Its space stays
/// reserved when there's no heart rate, so nothing jumps when the watch drops.
struct HeartRateZoneBar: View {
    let ride: RideController
    @AppStorage(RideController.maxHeartRateKey) private var maxHeartRate = HeartRateZones.defaultMax

    static let height: CGFloat = 7
    /// Zones 1 to 5: grey, blue, green, orange, red.
    static let colours: [Color] = [
        Color(white: 0.62),
        Color(red: 0.22, green: 0.52, blue: 1.0),
        Color(red: 0.18, green: 0.80, blue: 0.32),
        Color.orange,
        Color(red: 0.95, green: 0.15, blue: 0.15),
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let zones = HeartRateZones(maxHeartRate: maxHeartRate)
            if let bpm = ride.heartRate.bpm(at: context.date) {
                let zone = ride.heartRateZone ?? zones.zone(for: bpm)
                strip(zone: zone, position: zones.position(of: bpm, in: zone))
                    .accessibilityElement()
                    .accessibilityLabel(zone >= 1 ? "Heart rate zone \(zone)" : "Heart rate below zone 1")
            } else {
                Color.clear
            }
        }
        .frame(height: Self.height + 6)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func strip(zone: Int, position: Double) -> some View {
        GeometryReader { geo in
            let gap: CGFloat = 3
            let width = (geo.size.width - gap * CGFloat(HeartRateZones.count - 1)) / CGFloat(HeartRateZones.count)
            // Below zone 1 the marker waits at the left edge.
            let x = zone >= 1 ? CGFloat(zone - 1) * (width + gap) + CGFloat(position) * width : 0
            ZStack(alignment: .leading) {
                HStack(spacing: gap) {
                    ForEach(0..<HeartRateZones.count, id: \.self) { index in
                        Capsule()
                            .fill(Self.colours[index].opacity(index + 1 == zone ? 1 : 0.22))
                            .frame(width: width, height: Self.height)
                    }
                }
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: Self.height + 6)
                    .offset(x: min(max(x - 1.5, 0), geo.size.width - 3))
            }
            .frame(height: geo.size.height)
        }
    }
}
