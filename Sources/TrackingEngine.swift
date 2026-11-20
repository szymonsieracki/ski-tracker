import CoreLocation
import CoreMotion

/// GPS + barometr. Klasyfikacja: zjazd / wyciąg / postój (nie zapisywany).
final class TrackingEngine: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var segments: [Segment] = []
    @Published var current: Segment?
    @Published var isTracking = false
    @Published var currentSpeed = 0.0

    private let lm = CLLocationManager()
    private let altimeter = CMAltimeter()
    private var relAlt: Double?          // wysokość względna z barometru
    private var baseAlt: Double?         // kalibracja barometru do GPS
    private var window: [TrackPoint] = []
    private var candidate: SegmentKind?
    private var pending: [TrackPoint] = []

    // Progi (do strojenia na stoku)
    private let runVSpeed = -0.4         // m/s w dół
    private let liftVSpeed = 0.3         // m/s w górę
    private let minRunSpeed = 1.5        // m/s (poniżej = idziesz/stoisz)
    private let minLiftSpeed = 1.0
    private let confirmFixes = 5         // ile kolejnych pomiarów potwierdza zmianę

    override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        lm.activityType = .otherNavigation
        lm.distanceFilter = kCLDistanceFilterNone
        lm.pausesLocationUpdatesAutomatically = false
        lm.allowsBackgroundLocationUpdates = true
        lm.showsBackgroundLocationIndicator = true
    }

    func start() {
        lm.requestWhenInUseAuthorization()
        lm.requestAlwaysAuthorization()
        segments = []; current = nil; window = []; pending = []; candidate = nil
        baseAlt = nil; relAlt = nil
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] d, _ in
                if let d { self?.relAlt = d.relativeAltitude.doubleValue }
            }
        }
        lm.startUpdatingLocation()
        isTracking = true
    }

    func stop() {
        lm.stopUpdatingLocation()
        altimeter.stopRelativeAltitudeUpdates()
        closeCurrent()
        isTracking = false
        SessionStore.save(segments)
    }

    // MARK: CLLocationManagerDelegate
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        for l in locs where l.horizontalAccuracy > 0 && l.horizontalAccuracy < 25 && l.speed >= 0 {
            var alt = l.altitude
            if let rel = relAlt {                       // barometr = gładsza wysokość
                if baseAlt == nil { baseAlt = l.altitude - rel }
                alt = baseAlt! + rel
            }
            let p = TrackPoint(lat: l.coordinate.latitude, lon: l.coordinate.longitude,
                               alt: alt, speed: l.speed, t: l.timestamp)
            currentSpeed = l.speed
            process(p)
        }
    }

    // MARK: Logika
    private func classify() -> SegmentKind? {
        guard let f = window.first, let l = window.last else { return current?.kind }
        let dt = l.t.timeIntervalSince(f.t)
        guard dt >= 6 else { return current?.kind }
        let vs = (l.alt - f.alt) / dt
        let hs = window.map(\.speed).reduce(0, +) / Double(window.count)
        if vs < runVSpeed && hs > minRunSpeed { return .run }
        if vs > liftVSpeed && hs > minLiftSpeed { return .lift }
        return nil
    }

    private func process(_ p: TrackPoint) {
        window.append(p)
        if window.count > 12 { window.removeFirst() }
        let kind = classify()

        if kind == current?.kind {
            candidate = nil; pending = []
            if current != nil { current?.points.append(p) }
            return
        }
        if candidate == kind { pending.append(p) } else { candidate = kind; pending = [p] }

        if pending.count >= confirmFixes {          // zmiana stanu potwierdzona
            closeCurrent()
            if let k = kind { current = Segment(kind: k, points: pending) }
            candidate = nil; pending = []
        } else if current != nil {
            current?.points.append(p)
        }
    }

    private func closeCurrent() {
        guard let c = current else { return }
        let ok = c.kind == .lift ? c.duration > 30 : (c.duration > 10 && c.distance > 50)
        if ok { segments.append(c) }
        current = nil
    }
}

enum SessionStore {
    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("last_session.json")
    }
    static func save(_ s: [Segment]) { try? JSONEncoder().encode(s).write(to: url) }
    static func load() -> [Segment] {
        (try? JSONDecoder().decode([Segment].self, from: Data(contentsOf: url))) ?? []
    }
}
