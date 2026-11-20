import SwiftUI
import MapKit

@main
struct SkiTrackerApp: App {
    @StateObject private var engine = TrackingEngine()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(engine) }
    }
}

struct ContentView: View {
    @EnvironmentObject var engine: TrackingEngine
    @State private var showSummary = false

    var runs: [Segment] { engine.segments.filter { $0.kind == .run } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(Fmt.kmh(engine.currentSpeed))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                Text(statusText).foregroundStyle(.secondary)
                HStack {
                    stat("Zjazdy", "\(runs.count)")
                    stat("Dystans", Fmt.km(runs.reduce(0) { $0 + $1.distance }))
                    stat("Vmax", Fmt.kmh(runs.map(\.maxSpeed).max() ?? 0))
                }
                Button(engine.isTracking ? "Zakończ" : "Start") {
                    if engine.isTracking { engine.stop(); showSummary = true } else { engine.start() }
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isTracking ? .red : .green)
                .controlSize(.large)

                if !engine.isTracking && !SessionStore.load().isEmpty {
                    Button("Ostatni dzień") { showSummary = true }
                }
            }
            .padding()
            .navigationTitle("Ski Tracker")
            .navigationDestination(isPresented: $showSummary) {
                SummaryView(segments: engine.segments.isEmpty ? SessionStore.load() : engine.segments)
            }
        }
    }

    var statusText: String {
        switch engine.current?.kind {
        case .run: "⛷️ Zjazd"
        case .lift: "🚡 Wyciąg"
        case nil: engine.isTracking ? "Postój / oczekiwanie" : "Gotowy"
        }
    }

    func stat(_ t: String, _ v: String) -> some View {
        VStack { Text(v).font(.title3.bold()); Text(t).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity)
    }
}

struct SummaryView: View {
    let segments: [Segment]
    var runs: [Segment] { segments.filter { $0.kind == .run } }

    var body: some View {
        VStack(spacing: 0) {
            Map {
                ForEach(segments) { s in
                    MapPolyline(coordinates: s.coords)
                        .stroke(s.kind == .run ? Color.red : Color.blue.opacity(0.6),
                                style: StrokeStyle(lineWidth: s.kind == .run ? 5 : 3,
                                                   dash: s.kind == .lift ? [6, 4] : []))
                }
            }
            .mapStyle(.hybrid(elevation: .realistic))
            .frame(height: 320)

            List {
                Section("Podsumowanie") {
                    row("Zjazdy", "\(runs.count)")
                    row("Łączny dystans", Fmt.km(runs.reduce(0) { $0 + $1.distance }))
                    row("Czas zjazdów", Fmt.time(runs.reduce(0) { $0 + $1.duration }))
                    row("Przewyższenie", String(format: "%.0f m", runs.reduce(0) { $0 + $1.verticalDrop }))
                    row("Vmax", Fmt.kmh(runs.map(\.maxSpeed).max() ?? 0))
                }
                Section("Zjazdy") {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { i, r in
                        VStack(alignment: .leading) {
                            Text("Zjazd \(i + 1)").bold()
                            Text("\(Fmt.km(r.distance)) · \(Fmt.time(r.duration)) · śr. \(Fmt.kmh(r.avgSpeed)) · max \(Fmt.kmh(r.maxSpeed)) · ↓\(Int(r.verticalDrop)) m")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Podsumowanie")
    }

    func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a); Spacer(); Text(b).foregroundStyle(.secondary) }
    }
}
