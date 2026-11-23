import Foundation

enum GPX {
    /// Zapisuje GPX do pliku tymczasowego i zwraca jego adres (do udostępnienia).
    static func write(segments: [Segment], title: String) -> URL? {
        let iso = ISO8601DateFormatter()
        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="SkiTracker" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata><name>\(title)</name></metadata>

        """
        for (i, s) in segments.enumerated() {
            let label = s.kind == .run ? "Zjazd" : "Wyciag"
            x += "<trk><name>\(label) \(i + 1)</name><trkseg>\n"
            for p in s.points {
                x += "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\"><ele>\(String(format: "%.1f", p.alt))</ele><time>\(iso.string(from: p.t))</time></trkpt>\n"
            }
            x += "</trkseg></trk>\n"
        }
        x += "</gpx>\n"

        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let date = f.string(from: segments.first?.points.first?.t ?? Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("narty-\(date).gpx")
        do { try x.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }
}
