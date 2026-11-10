import CoreLocation
import Foundation

/// GPS for one workout. Keeps every fix worth keeping and nothing else: a fix is dropped when it
/// is stale, when the receiver is unsure to more than 50 m, or when it would add a jump no human
/// could have run. Without that filter a phone standing still at a traffic light "runs" 200 m.
@MainActor
final class RouteRecorder: NSObject, ObservableObject {
    /// What the route has so far, oldest first.
    @Published private(set) var points: [RoutePoint] = []
    /// Metres along the route.
    @Published private(set) var distance: Double = 0
    /// Metres per second from the receiver, smoothed over the last few fixes.
    @Published private(set) var speed: Double = 0
    /// Horizontal accuracy of the newest fix, in metres; nil before the first one.
    @Published private(set) var accuracy: Double?
    @Published private(set) var authorization: CLAuthorizationStatus
    /// Set when the user has to be told something: permission refused, location off.
    @Published private(set) var problem: String?

    private let manager = CLLocationManager()
    private var startedAt: Date?
    /// A workout is running and wants fixes. The first time anyone records, the permission
    /// sheet is still up when `start` is called, so the answer has to start the receiver.
    private var wantsUpdates = false
    /// The last fix kept, for the speed sanity check.
    private var previous: CLLocation?
    /// The last fix distance was counted from. It only moves once the phone has gone further
    /// than the receiver's own error — see `take`.
    private var anchor: CLLocation?
    private var recentSpeeds: [Double] = []
    /// Beats per minute to stamp on the next fix; the live band session feeds this.
    var heartRate: Int = 0
    private var sport: Sport = .run

    /// Core Location hands over its last cached fix first, which can be hours and kilometres
    /// old. Without this check every workout starts with a teleport.
    private static let maxAge: TimeInterval = 5

    /// How far off a fix may be before it is thrown away, and how fast the sport can plausibly
    /// go. A bike in a city gets more rope than a runner, because it covers more ground between
    /// fixes and spends longer in the shadow of buildings.
    private var maxAccuracy: Double { sport.tempo == .speed ? 40 : 25 }
    private var maxSpeed: Double { sport.tempo == .speed ? 25 : 12 }
    /// Below this the phone has not meaningfully moved, however good the fix claims to be.
    private static let minimumStep: Double = 3

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // Best, not BestForNavigation: the latter is for turn-by-turn in a car and assumes
        // the phone is plugged in. Automatic pausing has to stay off — Core Location decides on
        // its own that you have stopped and then takes its time coming back, which eats the end
        // of a workout. Auto-pause is the recorder's job, not the receiver's.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    func requestAccess() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if !isAuthorized {
            problem = String(localized: "Openband can't see your location. Turn it on in Settings to map a workout.")
        }
    }

    func start(_ sport: Sport, at date: Date) {
        self.sport = sport
        manager.activityType = sport.tempo == .speed ? .otherNavigation : .fitness
        points = []
        distance = 0
        speed = 0
        accuracy = nil
        previous = nil
        anchor = nil
        recentSpeeds = []
        startedAt = date
        wantsUpdates = true
        problem = nil
        guard CLLocationManager.locationServicesEnabled() else {
            problem = String(localized: "Location services are off, so this workout has no map.")
            return
        }
        guard isAuthorized else { requestAccess(); return }
        beginUpdates()
    }

    private func beginUpdates() {
        guard wantsUpdates, isAuthorized else { return }
        if manager.accuracyAuthorization == .reducedAccuracy {
            problem = String(localized: "Precise Location is off, so this route will be rough. Turn it on in Settings › Openband › Location.")
        }
        // Background updates need the `location` background mode in Info.plist — without it
        // this line throws rather than failing quietly. The blue bar stays on: an app that
        // follows you should say so.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    /// A pause keeps the receiver warm but stops the route growing.
    func pause() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
    }

    func resume() {
        previous = nil
        anchor = nil
        wantsUpdates = true
        beginUpdates()
    }

    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }
}

extension RouteRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations
        Task { @MainActor in self.take(fixes) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            guard self.isAuthorized else { return }
            self.problem = nil
            // The answer arrives after `start` has already given up on asking.
            self.beginUpdates()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A transient "unknown location" is normal indoors; only a denial is worth saying.
        guard (error as? CLError)?.code == .denied else { return }
        Task { @MainActor in
            self.problem = String(localized: "Openband can't see your location. Turn it on in Settings to map a workout.")
        }
    }

    private func take(_ fixes: [CLLocation]) {
        guard let startedAt else { return }
        for fix in fixes {
            // A negative accuracy means the fix is invalid, not that it is perfect.
            guard abs(fix.timestamp.timeIntervalSinceNow) < Self.maxAge,
                  fix.horizontalAccuracy > 0, fix.horizontalAccuracy <= maxAccuracy,
                  fix.timestamp >= startedAt else { continue }
            accuracy = fix.horizontalAccuracy

            if let previous {
                let dt = fix.timestamp.timeIntervalSince(previous.timestamp)
                // Out of order, or a jump faster than the sport can go: the receiver, not the
                // runner.
                guard dt > 0, fix.distance(from: previous) / dt <= maxSpeed else { continue }
            }
            previous = fix

            // Distance is measured from an anchor rather than from the last fix. Standing at a
            // traffic light, every fix wobbles a few metres; adding each wobble is how a phone
            // on a wall "runs" 200 m. Instead the anchor holds until the phone has genuinely
            // gone further than the receiver's own error, and then the whole step counts — so
            // slow movement is not thrown away either.
            if let anchor {
                let step = fix.distance(from: anchor)
                if step > max(Self.minimumStep, fix.horizontalAccuracy / 2) {
                    distance += step
                    self.anchor = fix
                }
            } else {
                anchor = fix
            }

            recentSpeeds.append(max(0, fix.speed))
            if recentSpeeds.count > 5 { recentSpeeds.removeFirst() }
            speed = recentSpeeds.reduce(0, +) / Double(recentSpeeds.count)
            points.append(RoutePoint(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                                     altitude: fix.verticalAccuracy > 0 ? Float(fix.altitude) : .nan,
                                     offset: Float(fix.timestamp.timeIntervalSince(startedAt)),
                                     heartRate: Int16(clamping: heartRate)))
        }
    }
}
