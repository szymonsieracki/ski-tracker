import SwiftUI
import MapKit
import Charts

@main
struct SkiTrackerApp: App {
    @StateObject private var engine = TrackingEngine()
    @StateObject private var skiMap = SkiMapStore()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(skiMap)
                .task { await skiMap.load() }
        }
    }
}

// MARK: - Ekran główny
struct ContentView: View {
    @EnvironmentObject var engine: TrackingEngine
    @State private var showSummary = false

    var runs: [Segment] { engine.segments.filter { $0.kind == .run } }
    var runsWithCurrent: [Segment] {
        runs + ((engine.current?.kind == .run) ? [engine.current!] : [])
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(Fmt.kmh(engine.currentSpeed))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                Text(statusText).foregroundStyle(.secondary)
                HStack {
                    stat("Zjazdy", "\(runs.count)")
                    stat("Dystans", Fmt.km(runsWithCurrent.reduce(0) { $0 + $1.distance }))
                    stat("Vmax", Fmt.kmh(runsWithCurrent.map(\.maxSpeed).max() ?? 0))
                }
                Button(engine.isTracking ? "Zakończ" : "Start") {
                    if engine.isTracking { engine.stop(); showSummary = true } else { engine.start() }
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isTracking ? .red : .green)
                .controlSize(.large)

                if !engine.isTracking {
                    HStack(spacing: 24) {
                        NavigationLink("Historia") { HistoryView() }
                        NavigationLink("Mapa ośrodka") { SkiAreaMapView() }
                    }
                }
            }
            .padding()
            .navigationTitle("Ski Tracker")
            .navigationDestination(isPresented: $showSummary) {
                SummaryView(segments: SessionStore.all().first?.segments ?? engine.segments,
                            title: "Ostatni dzień")
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

// MARK: - Historia
struct HistoryView: View {
    @State private var sessions = SessionStore.all()

    var body: some View {
        List {
            if sessions.isEmpty { Text("Brak zapisanych dni.").foregroundStyle(.secondary) }
            ForEach(sessions) { s in
                let title = s.date.formatted(date: .complete, time: .omitted)
                NavigationLink {
                    SummaryView(segments: s.segments, title: title)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).bold()
                        Text("\(s.runs.count) zjazdów · \(Fmt.km(s.runs.reduce(0) { $0 + $1.distance })) · Vmax \(Fmt.kmh(s.runs.map(\.maxSpeed).max() ?? 0))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { idx in
                idx.map { sessions[$0].id }.forEach(SessionStore.delete)
                sessions = SessionStore.all()
            }
        }
        .navigationTitle("Historia")
        .toolbar { EditButton() }
    }
}

// MARK: - Warstwa mapy ośrodka
func difficultyColor(_ d: String) -> Color {
    switch d {
    case "novice": .green
    case "easy": .blue
    case "intermediate": .red
    case "advanced", "expert": .black
    default: .gray
    }
}

struct SkiLayers: MapContent {
    let data: SkiMapData
    var body: some MapContent {
        ForEach(data.pistes) { p in
            MapPolyline(coordinates: p.coords.map(\.cl))
                .stroke(difficultyColor(p.difficulty).opacity(0.85), lineWidth: 3)
        }
        ForEach(data.lifts) { l in
            MapPolyline(coordinates: l.coords.map(\.cl))
                .stroke(.yellow, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
        }
    }
}

struct SkiAreaMapView: View {
    @EnvironmentObject var skiMap: SkiMapStore

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: .init(latitude: 46.27, longitude: 10.84),
                span: .init(latitudeDelta: 0.16, longitudeDelta: 0.2)))) {
                UserAnnotation()
                if let d = skiMap.data { SkiLayers(data: d) }
            }
            .mapStyle(.hybrid(elevation: .realistic))
            .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }

            VStack(spacing: 4) {
                if skiMap.loading { ProgressView("Pobieram trasy…") }
                if let e = skiMap.error { Text(e).font(.caption).foregroundStyle(.red) }
                if let d = skiMap.data {
                    Text("\(d.pistes.count) tras · \(d.lifts.count) wyciągów · © współtwórcy OpenStreetMap")
                        .font(.caption2)
                }
                Text("zielona/niebieska/czerwona/czarna = trudność · żółte przerywane = wyciągi")
                    .font(.caption2)
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(8)
        }
        .navigationTitle("Madonna · Folgarida · Marilleva")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { Task { await skiMap.load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
        }
    }
}

// MARK: - Podsumowanie dnia
struct SummaryView: View {
    @EnvironmentObject var skiMap: SkiMapStore
    let segments: [Segment]
    let title: String
    @State private var showPistes = true
    @State private var gpxURL: URL?

    var runs: [Segment] { segments.filter { $0.kind == .run } }

    var region: MKCoordinateRegion {
        let pts = segments.flatMap(\.points)
        guard let f = pts.first else {
            return MKCoordinateRegion(center: .init(latitude: 46.27, longitude: 10.84),
                                      span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1))
        }
        var minLat = f.lat, maxLat = f.lat, minLon = f.lon, maxLon = f.lon
        for p in pts {
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
        }
        return MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: .init(latitudeDelta: max(0.01, (maxLat - minLat) * 1.3),
                        longitudeDelta: max(0.01, (maxLon - minLon) * 1.3)))
    }

    var body: some View {
        VStack(spacing: 0) {
            Map(initialPosition: .region(region)) {
                if showPistes, let d = skiMap.data { SkiLayers(data: d) }
                ForEach(segments) { s in
                    MapPolyline(coordinates: s.coords)
                        .stroke(s.kind == .run ? Color.purple : Color.cyan,
                                style: StrokeStyle(lineWidth: s.kind == .run ? 5 : 3,
                                                   dash: s.kind == .lift ? [6, 4] : []))
                }
            }
            .mapStyle(.hybrid(elevation: .realistic))
            .frame(height: 320)

            Toggle("Pokaż trasy i wyciągi ośrodka", isOn: $showPistes)
                .font(.caption).padding(.horizontal).padding(.vertical, 6)

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
                        NavigationLink {
                            RunDetailView(run: r, index: i + 1)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Zjazd \(i + 1)").bold()
                                if let n = Matcher.names(for: r, map: skiMap.data) {
                                    Text(n).font(.subheadline)
                                }
                                Text("\(Fmt.km(r.distance)) · \(Fmt.time(r.duration)) · śr. \(Fmt.kmh(r.avgSpeed)) · max \(Fmt.kmh(r.maxSpeed)) · ↓\(Int(r.verticalDrop)) m")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let gpxURL { ShareLink(item: gpxURL) { Image(systemName: "square.and.arrow.up") } }
        }
        .onAppear { gpxURL = GPX.write(segments: segments, title: title) }
    }

    func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a); Spacer(); Text(b).foregroundStyle(.secondary) }
    }
}

// MARK: - Szczegóły zjazdu z wykresami
struct RunDetailView: View {
    @EnvironmentObject var skiMap: SkiMapStore
    let run: Segment
    let index: Int

    var series: [(t: Double, kmh: Double, alt: Double)] {
        guard let s = run.points.first?.t else { return [] }
        return run.points.map { ($0.t.timeIntervalSince(s), $0.speed * 3.6, $0.alt) }
    }

    var body: some View {
        List {
            if let n = Matcher.names(for: run, map: skiMap.data) {
                Section("Trasa") { Text(n) }
            }
            Section("Statystyki") {
                row("Dystans", Fmt.km(run.distance))
                row("Czas", Fmt.time(run.duration))
                row("Średnia", Fmt.kmh(run.avgSpeed))
                row("Maksymalna", Fmt.kmh(run.maxSpeed))
                row("Przewyższenie", String(format: "%.0f m", run.verticalDrop))
            }
            Section("Prędkość (km/h)") {
                Chart(series, id: \.t) {
                    LineMark(x: .value("s", $0.t), y: .value("km/h", $0.kmh))
                }
                .frame(height: 160)
            }
            Section("Wysokość (m n.p.m.)") {
                Chart(series, id: \.t) {
                    AreaMark(x: .value("s", $0.t), y: .value("m", $0.alt))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 160)
            }
        }
        .navigationTitle("Zjazd \(index)")
        .navigationBarTitleDisplayMode(.inline)
    }

    func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a); Spacer(); Text(b).foregroundStyle(.secondary) }
    }
}
