import Foundation

/// One fix on a route. Stored packed (28 bytes each), so an hour at 1 Hz is about 100 kB.
struct RoutePoint: Equatable, Sendable {
    /// Degrees.
    var latitude: Double
    var longitude: Double
    /// Metres above sea level; `.nan` when the fix had none.
    var altitude: Float
    /// Seconds since the workout started.
    var offset: Float
    /// Beats per minute from the band at this moment, or 0.
    var heartRate: Int16

    init(latitude: Double, longitude: Double, altitude: Float = .nan, offset: Float, heartRate: Int16 = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.offset = offset
        self.heartRate = heartRate
    }
}

enum RouteCodec {
    /// 8 + 8 + 4 + 4 + 2, rounded up to a 4-byte boundary.
    static let stride = 28

    static func encode(_ points: [RoutePoint]) -> Data {
        var data = Data(capacity: points.count * stride)
        for p in points {
            append(&data, p.latitude.bitPattern)
            append(&data, p.longitude.bitPattern)
            append(&data, UInt32(p.altitude.bitPattern))
            append(&data, UInt32(p.offset.bitPattern))
            append(&data, UInt16(bitPattern: p.heartRate))
            data.append(contentsOf: [0, 0])
        }
        return data
    }

    static func decode(_ data: Data) -> [RoutePoint] {
        guard !data.isEmpty, data.count % stride == 0 else { return [] }
        var points: [RoutePoint] = []
        points.reserveCapacity(data.count / stride)
        var index = data.startIndex
        while index < data.endIndex {
            let lat = Double(bitPattern: read(data, index, as: UInt64.self))
            let lon = Double(bitPattern: read(data, index + 8, as: UInt64.self))
            let alt = Float(bitPattern: read(data, index + 16, as: UInt32.self))
            let off = Float(bitPattern: read(data, index + 20, as: UInt32.self))
            let hr = Int16(bitPattern: read(data, index + 24, as: UInt16.self))
            points.append(RoutePoint(latitude: lat, longitude: lon, altitude: alt, offset: off, heartRate: hr))
            index += stride
        }
        return points
    }

    private static func append<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_ data: Data, _ offset: Data.Index, as: T.Type) -> T {
        var value = T()
        withUnsafeMutableBytes(of: &value) { raw in
            for i in 0 ..< MemoryLayout<T>.size { raw[i] = data[offset + i] }
        }
        return T(littleEndian: value)
    }
}

enum RouteGeometry {
    static let earthRadius = 6_371_008.8

    /// Great-circle metres between two fixes.
    static func distance(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dφ = φ2 - φ1
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * asin(min(1, sqrt(max(0, h))))
    }

    /// Metres along the whole route.
    static func length(_ points: [RoutePoint]) -> Double {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// Metres climbed, ignoring the noise a barometer-less fix produces: only rises of more than
    /// `threshold` between two kept samples count.
    static func elevationGain(_ points: [RoutePoint], threshold: Double = 3) -> Double {
        var gain = 0.0
        var reference: Double?
        for point in points where point.altitude.isFinite {
            let altitude = Double(point.altitude)
            guard let last = reference else { reference = altitude; continue }
            if altitude - last > threshold {
                gain += altitude - last
                reference = altitude
            } else if last - altitude > threshold {
                reference = altitude
            }
        }
        return gain
    }

    /// The route's bounds, or nil when it is empty.
    struct Bounds: Equatable {
        var minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double
        var centreLatitude: Double { (minLatitude + maxLatitude) / 2 }
        var centreLongitude: Double { (minLongitude + maxLongitude) / 2 }
    }

    static func bounds(_ points: [RoutePoint]) -> Bounds? {
        guard let first = points.first else { return nil }
        var b = Bounds(minLatitude: first.latitude, maxLatitude: first.latitude,
                       minLongitude: first.longitude, maxLongitude: first.longitude)
        for p in points.dropFirst() {
            b.minLatitude = min(b.minLatitude, p.latitude)
            b.maxLatitude = max(b.maxLatitude, p.latitude)
            b.minLongitude = min(b.minLongitude, p.longitude)
            b.maxLongitude = max(b.maxLongitude, p.longitude)
        }
        return b
    }

    /// The route as points in a unit square, y already flipped for drawing (0 at the top).
    ///
    /// Longitude degrees shrink with latitude, so they are scaled by cos(latitude) before the
    /// route is fitted; without it every route north or south of the equator comes out stretched.
    /// The shape keeps its aspect ratio and is centred in the square.
    static func normalised(_ points: [RoutePoint]) -> [(x: Double, y: Double)] {
        guard let b = bounds(points), points.count > 1 else { return [] }
        let scale = cos(b.centreLatitude * .pi / 180)
        let width = (b.maxLongitude - b.minLongitude) * scale
        let height = b.maxLatitude - b.minLatitude
        let span = max(width, height)
        guard span > 0 else { return points.map { _ in (0.5, 0.5) } }
        let xInset = (span - width) / 2
        let yInset = (span - height) / 2
        return points.map { p in
            let x = ((p.longitude - b.minLongitude) * scale + xInset) / span
            let y = 1 - ((p.latitude - b.minLatitude) + yInset) / span
            return (x, y)
        }
    }

    /// Douglas–Peucker, so a 3,600-point route draws as a few hundred without visibly changing.
    /// `tolerance` is in metres.
    static func simplified(_ points: [RoutePoint], tolerance: Double = 4) -> [RoutePoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var farthest = first
            var best = 0.0
            for i in (first + 1) ..< last {
                let d = perpendicular(points[i], points[first], points[last])
                if d > best { best = d; farthest = i }
            }
            if best > tolerance {
                keep[farthest] = true
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }
        return points.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    /// Metres from `p` to the line through `a` and `b`, in a local flat projection.
    private static func perpendicular(_ p: RoutePoint, _ a: RoutePoint, _ b: RoutePoint) -> Double {
        let scale = cos(a.latitude * .pi / 180) * earthRadius * .pi / 180
        let metresPerDegree = earthRadius * .pi / 180
        let px = (p.longitude - a.longitude) * scale, py = (p.latitude - a.latitude) * metresPerDegree
        let bx = (b.longitude - a.longitude) * scale, by = (b.latitude - a.latitude) * metresPerDegree
        let lengthSquared = bx * bx + by * by
        guard lengthSquared > 0 else { return sqrt(px * px + py * py) }
        let t = max(0, min(1, (px * bx + py * by) / lengthSquared))
        let dx = px - t * bx, dy = py - t * by
        return sqrt(dx * dx + dy * dy)
    }
}
