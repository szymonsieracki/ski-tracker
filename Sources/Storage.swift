import Foundation

struct Session: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var segments: [Segment]
    var runs: [Segment] { segments.filter { $0.kind == .run } }
}

/// Historia wielu dni zapisywana w katalogu Documents.
enum SessionStore {
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions.json")
    }

    static func all() -> [Session] {
        (try? JSONDecoder().decode([Session].self, from: Data(contentsOf: url))) ?? []
    }

    private static func write(_ s: [Session]) {
        try? JSONEncoder().encode(s).write(to: url, options: .atomic)
    }

    static func add(_ segments: [Segment]) {
        guard !segments.isEmpty else { return }
        var list = all()
        let date = segments.first?.points.first?.t ?? Date()
        list.insert(Session(date: date, segments: segments), at: 0)
        write(list)
    }

    static func delete(id: UUID) {
        write(all().filter { $0.id != id })
    }
}
