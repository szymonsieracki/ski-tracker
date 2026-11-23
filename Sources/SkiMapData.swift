import Foundation
import CoreLocation

/// Trasy i wyciągi z OpenStreetMap (Overpass API) dla Madonna di Campiglio + Folgarida-Marilleva.
struct Coord: Codable {
    var lat: Double
    var lon: Double
    var cl: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

struct Piste: Identifiable, Codable {
    var id: Int
    var name: String
    var difficulty: String   // novice, easy, intermediate, advanced, expert
    var coords: [Coord]
}

struct Lift: Identifiable, Codable {
    var id: Int
    var name: String
    var kind: String
    var coords: [Coord]
}

struct SkiMapData: Codable {
    var pistes: [Piste]
    var lifts: [Lift]
    var fetched: Date
}

@MainActor
final class SkiMapStore: ObservableObject {
    @Published var data: SkiMapData?
    @Published var loading = false
    @Published var error: String?

    // Obszar: Madonna di Campiglio, Pinzolo, Folgarida, Marilleva (z zapasem)
    private let bbox = "46.15,10.70,46.40,10.95"   // south,west,north,east

    private var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("skimap.json")
    }

    func load(force: Bool = false) async {
        if data == nil, let d = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(SkiMapData.self, from: d) {
            data = cached
        }
        let stale = data.map { Date().timeIntervalSince($0.fetched) > 30 * 86400 } ?? true
        guard force || stale else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let fresh = try await fetch()
            data = fresh
            try? JSONEncoder().encode(fresh).write(to: cacheURL, options: .atomic)
        } catch {
            self.error = "Nie udało się pobrać mapy tras: \(error.localizedDescription)"
        }
    }

    private struct Resp: Decodable {
        struct El: Decodable {
            struct Pt: Decodable { let lat: Double; let lon: Double }
            let id: Int
            let tags: [String: String]?
            let geometry: [Pt]?
        }
        let elements: [El]
    }

    private func fetch() async throws -> SkiMapData {
        let lifts = "chair_lift|gondola|cable_car|mixed_lift|drag_lift|t-bar|j-bar|platter|magic_carpet|rope_tow"
        let query = """
        [out:json][timeout:90];
        (
          way["piste:type"="downhill"](\(bbox));
          way["aerialway"~"^(\(lifts))$"](\(bbox));
        );
        out tags geom;
        """
        var req = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 100
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("SkiTracker/1.0", forHTTPHeaderField: "User-Agent")
        let enc = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        req.httpBody = "data=\(enc)".data(using: .utf8)

        let (d, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let r = try JSONDecoder().decode(Resp.self, from: d)

        var pistes: [Piste] = [], liftList: [Lift] = []
        for e in r.elements {
            guard let g = e.geometry, g.count > 1, let t = e.tags else { continue }
            let coords = g.map { Coord(lat: $0.lat, lon: $0.lon) }
            let name = t["name"] ?? t["piste:name"] ?? t["ref"] ?? "Bez nazwy"
            if t["piste:type"] == "downhill" {
                pistes.append(Piste(id: e.id, name: name,
                                    difficulty: t["piste:difficulty"] ?? "unknown", coords: coords))
            } else if let k = t["aerialway"] {
                liftList.append(Lift(id: e.id, name: name, kind: k, coords: coords))
            }
        }
        return SkiMapData(pistes: pistes, lifts: liftList, fetched: Date())
    }
}

// MARK: - Dopasowanie przejazdów do nazw tras i wyciągów
enum Matcher {
    /// Odległość punktu od odcinka w metrach (przybliżenie płaskie, wystarczające na skali stoku).
    private static func dist(_ p: Coord, _ a: Coord, _ b: Coord) -> Double {
        let k = cos(p.lat * .pi / 180) * 111_320, m = 110_540.0
        let px = p.lon * k, py = p.lat * m
        let ax = a.lon * k, ay = a.lat * m, bx = b.lon * k, by = b.lat * m
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / len2))
        let cx = ax + t * dx, cy = ay + t * dy
        return hypot(px - cx, py - cy)
    }

    private static func nearest(_ p: Coord, lines: [(String, [Coord])], limit: Double) -> String? {
        var best: (String, Double)?
        for (name, c) in lines {
            for i in 0..<(c.count - 1) {
                let d = dist(p, c[i], c[i + 1])
                if d < limit, d < (best?.1 ?? .infinity) { best = (name, d) }
            }
        }
        return best?.0
    }

    /// Zwraca nazwy tras/wyciągów w kolejności przejazdu, np. "Genziana → Boch".
    static func names(for seg: Segment, map: SkiMapData?) -> String? {
        guard let map, seg.points.count > 2 else { return nil }
        let lines: [(String, [Coord])] = seg.kind == .run
            ? map.pistes.map { ($0.name, $0.coords) }
            : map.lifts.map { ($0.name, $0.coords) }
        let limit = seg.kind == .run ? 35.0 : 50.0
        let step = max(1, seg.points.count / 15)
        let samples = stride(from: 0, to: seg.points.count, by: step).map { seg.points[$0] }

        var order: [String] = [], count: [String: Int] = [:], n = 0
        for p in samples {
            n += 1
            if let name = nearest(Coord(lat: p.lat, lon: p.lon), lines: lines, limit: limit) {
                if count[name] == nil { order.append(name) }
                count[name, default: 0] += 1
            }
        }
        let found = order.filter { Double(count[$0] ?? 0) / Double(n) >= 0.25 }
        return found.isEmpty ? nil : found.joined(separator: " → ")
    }
}
