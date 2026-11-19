import BikeDashCore
import SwiftUI

/// Finished rides, newest first. Tap one for its numbers; swipe to delete.
struct HistoryView: View {
    let history: RideHistory
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if history.rides.isEmpty {
                    ContentUnavailableView(
                        "No rides yet",
                        systemImage: "bicycle",
                        description: Text("Rides you finish show up here.")
                    )
                } else {
                    List {
                        ForEach(history.rides) { record in
                            NavigationLink(value: record) {
                                HistoryRow(record: record)
                            }
                            .listRowBackground(Color.black)
                        }
                        .onDelete { history.delete(at: $0) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: RideRecord.self) { record in
                RideSummaryView(record: record)
            }
        }
    }
}

struct HistoryRow: View {
    let record: RideRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                    .font(.headline)
                    .foregroundStyle(Color.white)
                Spacer()
                Text(RideFormat.distance(record.distance) + " km")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Color.white)
            }
            Text(detail)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.dim)
            if let routeName = record.routeName {
                Label(routeName, systemImage: "map")
                    .font(.subheadline)
                    .foregroundStyle(Theme.route)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        // The divider starts at the row's edge, not at the route label's text.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }

    private var detail: String {
        var parts = [RideFormat.clock(record.movingTime)]
        if let speed = record.averageSpeed {
            parts.append(RideFormat.speed(speed) + " km/h")
        }
        if let bpm = record.averageHeartRate {
            parts.append("\(bpm) bpm")
        }
        parts.append(RideFormat.metres(record.ascent) + " m up")
        if !record.splits.isEmpty {
            parts.append("\(record.splits.count) laps")
        }
        return parts.joined(separator: " · ")
    }
}
