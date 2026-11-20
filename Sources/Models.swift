import CoreLocation

enum SegmentKind: String, Codable { case run, lift }

struct TrackPoint: Codable {
    let lat, lon, alt, speed: Double   // speed w m/s
    let t: Date
}

struct Segment: Identifiable, Codable {
    var id = UUID()
    var kind: SegmentKind
    var points: [TrackPoint] = []

    var coords: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }
    var distance: Double {   // metry
        zip(points, points.dropFirst()).reduce(0) {
            $0 + CLLocation(latitude: $1.0.lat, longitude: $1.0.lon)
                .distance(from: CLLocation(latitude: $1.1.lat, longitude: $1.1.lon))
        }
    }
    var duration: TimeInterval {
        guard let a = points.first, let b = points.last else { return 0 }
        return b.t.timeIntervalSince(a.t)
    }
    var avgSpeed: Double { duration > 0 ? distance / duration : 0 }
    var maxSpeed: Double { points.map(\.speed).max() ?? 0 }
    var verticalDrop: Double {
        guard let a = points.first, let b = points.last else { return 0 }
        return abs(a.alt - b.alt)
    }
}

enum Fmt {
    static func kmh(_ ms: Double) -> String { String(format: "%.1f km/h", ms * 3.6) }
    static func km(_ m: Double) -> String { String(format: "%.2f km", m / 1000) }
    static func time(_ s: TimeInterval) -> String {
        let i = Int(s); return String(format: "%d:%02d:%02d", i / 3600, i % 3600 / 60, i % 60)
    }
}
