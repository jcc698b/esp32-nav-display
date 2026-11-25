import CoreLocation
import Foundation

// ============================================================
//  地图数据打包：路线折线 + 周边道路 → 二进制 blob
//  协议见 docs/protocol.md（MAP_BEGIN / MAP_CHUNK / MAP_END / POS）
// ============================================================

struct OSMRoad {
    var kind: UInt8            // 0 支路 1 次干道 2 主干道
    var points: [CLLocationCoordinate2D]
}

extension Data {
    mutating func append(u8 v: UInt8) { append(contentsOf: [v]) }
    mutating func append(u16 v: UInt16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func append(u32 v: UInt32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func append(i16 v: Int16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func append(i32 v: Int32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
}

enum MapFrame {
    static let unitMeters = 2          // 1 个单位 = 2 米
    static let maxBlob = 32 * 1024     // 固件缓冲 32768

    /// 把 blob 拆成 BLE 帧
    static func frames(blob: Data, lineCount: Int, ref: CLLocationCoordinate2D) -> [Data] {
        guard !blob.isEmpty else { return [] }

        var out: [Data] = []

        var begin = Data([0x01])
        begin.append(u32: UInt32(blob.count))
        begin.append(u16: UInt16(lineCount))
        begin.append(i32: Int32((ref.latitude * 1e7).rounded()))
        begin.append(i32: Int32((ref.longitude * 1e7).rounded()))
        begin.append(u8: UInt8(unitMeters))
        out.append(begin)

        let chunk = 150
        var offset = 0
        while offset < blob.count {
            let n = min(chunk, blob.count - offset)
            var f = Data([0x02])
            f.append(u32: UInt32(offset))
            f.append(u16: UInt16(n))
            f.append(blob.subdata(in: offset..<(offset + n)))
            out.append(f)
            offset += n
        }

        var end = Data([0x03])
        end.append(u32: crc32(blob))
        out.append(end)
        return out
    }

    /// 位置包 0x10
    static func position(lat: Double, lon: Double, headingDeg: Double, speedKmh: Double,
                         distanceToTurn: Double, turn: Maneuver, arrived: Bool,
                         turnCoordinate: CLLocationCoordinate2D?) -> Data {
        var d = Data([0x10])
        d.append(i32: Int32((lat * 1e7).rounded()))
        d.append(i32: Int32((lon * 1e7).rounded()))
        d.append(u16: UInt16(max(0, min(3599, (headingDeg * 10).rounded()))))
        d.append(u16: UInt16(max(0, min(6553, (speedKmh * 10).rounded()))))
        d.append(u16: UInt16(max(0, min(65535, distanceToTurn.rounded()))))
        d.append(u8: turn.code)
        d.append(u8: UInt8((arrived ? 2 : 0) | 1))
        let tc = turnCoordinate ?? CLLocationCoordinate2D(latitude: lat, longitude: lon)
        d.append(i32: Int32((tc.latitude * 1e7).rounded()))
        d.append(i32: Int32((tc.longitude * 1e7).rounded()))
        return d
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data {
            c ^= UInt32(b)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : (c >> 1)
            }
        }
        return c ^ 0xFFFF_FFFF
    }
}

enum MapBlob {
    /// 以 center 为原点，取半径内的路线和道路，编码成 blob
    static func build(route: [CLLocationCoordinate2D],
                      roads: [OSMRoad],
                      center: CLLocationCoordinate2D,
                      radius: Double = 1600) -> (data: Data, lineCount: Int) {

        func local(_ c: CLLocationCoordinate2D) -> (Double, Double) {
            let x = (c.longitude - center.longitude) * 111_320.0 * cos(center.latitude * .pi / 180)
            let y = (c.latitude - center.latitude) * 110_540.0
            return (x, y)
        }

        var routeLines: [[(Double, Double)]] = []
        for run in clip(localPoints: route.map(local), radius: radius) {
            let s = simplify(run, tolerance: 5)
            if s.count >= 2 { routeLines.append(s) }
        }

        var roadLines: [(UInt8, [(Double, Double)])] = []
        for r in roads {
            // OSM 是 WGS-84；iOS 在国内给的定位/路线是 GCJ-02，先统一坐标系
            let fixed = r.points.map { GCJ.fromWGS84($0) }
            for run in clip(localPoints: fixed.map(local), radius: radius) {
                let s = simplify(run, tolerance: 7)
                if s.count >= 2 { roadLines.append((r.kind, s)) }
            }
        }
        roadLines.sort { $0.0 > $1.0 }

        var blob = Data()
        blob.append(u16: 0)                 // 行数先占位
        var lineCount = 0

        func appendLine(_ kind: UInt8, _ pts: [(Double, Double)]) {
            guard pts.count >= 2, pts.count <= 65535 else { return }
            var line = Data()
            line.append(u8: kind)
            line.append(u16: UInt16(pts.count))
            for p in pts {
                let ux = Int16(clamping: Int((p.0 / Double(MapFrame.unitMeters)).rounded()))
                let uy = Int16(clamping: Int((p.1 / Double(MapFrame.unitMeters)).rounded()))
                line.append(i16: ux)
                line.append(i16: uy)
            }
            // 放得下才加，避免最后整包回退成“只有路线”
            if blob.count + line.count <= MapFrame.maxBlob {
                blob.append(line)
                lineCount += 1
            }
        }

        // 路线优先，其次按道路等级从高到低填
        for line in routeLines { appendLine(3, line) }
        for line in roadLines { appendLine(line.0, line.1) }

        guard lineCount > 0 else { return (Data(), 0) }
        blob.replaceSubrange(0..<2,
                             with: Data([UInt8(lineCount & 0xff), UInt8((lineCount >> 8) & 0xff)]))
        return (blob, lineCount)
    }

    // MARK: - 几何

    private static func clip(localPoints: [(Double, Double)], radius: Double) -> [[(Double, Double)]] {
        var out: [[(Double, Double)]] = []
        var cur: [(Double, Double)] = []
        for p in localPoints {
            if hypot(p.0, p.1) <= radius {
                cur.append(p)
            } else {
                if cur.count >= 2 { out.append(cur) }
                cur = []
            }
        }
        if cur.count >= 2 { out.append(cur) }
        return out
    }

    /// Douglas-Peucker，输入输出都是米
    private static func simplify(_ pts: [(Double, Double)], tolerance: Double) -> [(Double, Double)] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true

        var stack: [(Int, Int)] = [(0, pts.count - 1)]
        while let seg = stack.popLast() {
            let a = seg.0, b = seg.1
            guard b > a + 1 else { continue }
            var maxD = 0.0
            var idx = -1
            for i in (a + 1)..<b {
                let d = pointLineDistance(pts[i], pts[a], pts[b])
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > tolerance, idx > 0 {
                keep[idx] = true
                stack.append((a, idx))
                stack.append((idx, b))
            }
        }
        var out: [(Double, Double)] = []
        out.reserveCapacity(pts.count)
        for (i, p) in pts.enumerated() where keep[i] { out.append(p) }
        return out
    }

    private static func pointLineDistance(_ p: (Double, Double), _ a: (Double, Double),
                                          _ b: (Double, Double)) -> Double {
        let dx = b.0 - a.0, dy = b.1 - a.1
        let len2 = dx * dx + dy * dy
        if len2 < 1e-9 { return hypot(p.0 - a.0, p.1 - a.1) }
        let t = max(0, min(1, ((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len2))
        return hypot(p.0 - (a.0 + dx * t), p.1 - (a.1 + dy * t))
    }
}

// ============================================================
//  OSM 周边道路（Overpass API）
// ============================================================

final class OSMBasemap {
    static let shared = OSMBasemap()

    private var cache: [String: [OSMRoad]] = [:]
    private var recent: [String] = []
    private var lastRequest = Date.distantPast
    private var inFlight = false

    func roads(around center: CLLocationCoordinate2D, radius: Double = 1500,
               completion: @escaping ([OSMRoad]) -> Void) {
        let key = String(format: "%.2f,%.2f", center.latitude, center.longitude)
        if let hit = cache[key] {
            completion(hit)
            return
        }
        guard !inFlight, Date().timeIntervalSince(lastRequest) > 1.2 else {
            completion([])
            return
        }
        inFlight = true
        lastRequest = Date()

        let r = min(radius, 1800)
        // Overpass 的 bbox 要用 WGS-84，而 center 是 GCJ-02
        let q = GCJ.toWGS84(center)
        let dLat = r / 110_540.0
        let dLon = r / (111_320.0 * max(0.15, cos(q.latitude * .pi / 180)))
        let s = q.latitude - dLat
        let n = q.latitude + dLat
        let w = q.longitude - dLon
        let e = q.longitude + dLon

        let query = """
        [out:json][timeout:8];way["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street)$"](\(s),\(w),\(n),\(e));out tags geom;
        """
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")

        // Overpass 主站国内经常连不上，按顺序换镜像（osm.ch 实测最快）
        let endpoints = [
            "https://overpass.osm.ch/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter",
            "https://overpass-api.de/api/interpreter",
        ]

        func parse(_ data: Data?) -> [OSMRoad] {
            guard let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let elements = obj["elements"] as? [[String: Any]] else { return [] }
            var roads: [OSMRoad] = []
            roads.reserveCapacity(min(elements.count, 3000))
            for el in elements.prefix(3000) {
                guard let tags = el["tags"] as? [String: String],
                      let hw = tags["highway"],
                      let geo = el["geometry"] as? [[String: Any]] else { continue }
                let kind: UInt8
                if hw == "motorway" || hw == "trunk" || hw == "primary" {
                    kind = 2
                } else if hw == "secondary" {
                    kind = 1
                } else {
                    kind = 0
                }
                var pts: [CLLocationCoordinate2D] = []
                pts.reserveCapacity(geo.count)
                for g in geo {
                    if let lat = g["lat"] as? Double, let lon = g["lon"] as? Double {
                        pts.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    }
                }
                if pts.count >= 2 { roads.append(OSMRoad(kind: kind, points: pts)) }
            }
            return roads
        }

        func finish(_ roads: [OSMRoad]) {
            DispatchQueue.main.async {
                self.inFlight = false
                if !roads.isEmpty {
                    self.cache[key] = roads
                    self.recent.append(key)
                    if self.recent.count > 12 {
                        let old = self.recent.removeFirst()
                        self.cache.removeValue(forKey: old)
                    }
                }
                completion(roads)
            }
        }

        func attempt(_ i: Int) {
            guard i < endpoints.count else { finish([]); return }
            var req = URLRequest(url: URL(string: endpoints[i])!)
            req.httpMethod = "POST"
            req.timeoutInterval = 12
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("NavDisplay/1.0", forHTTPHeaderField: "User-Agent")
            req.httpBody = body.data(using: .utf8)
            URLSession.shared.dataTask(with: req) { data, _, _ in
                let roads = parse(data)
                if roads.isEmpty {
                    attempt(i + 1)
                } else {
                    finish(roads)
                }
            }.resume()
        }
        attempt(0)
    }
}

// ============================================================
//  GCJ-02 坐标转换
//
//  中国大陆的 iOS 定位和 Apple 地图路线用的是 GCJ-02（火星坐标），
//  而 OpenStreetMap 是 WGS-84，直接混用会有 100~500 米的整体偏移。
//  所以 OSM 道路在打包前统一转到 GCJ-02。
//
//  如果实测发现地图整体偏移方向相反（说明设备给的是 WGS-84），
//  把 enabled 改成 false 即可。
// ============================================================

enum GCJ {
    static var enabled = true

    static func fromWGS84(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard enabled, !outOfChina(c) else { return c }
        let a = 6_378_245.0
        let ee = 0.00669342162296594323

        var dLat = transformLat(c.longitude - 105.0, c.latitude - 35.0)
        var dLon = transformLon(c.longitude - 105.0, c.latitude - 35.0)
        let radLat = c.latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)

        return CLLocationCoordinate2D(latitude: c.latitude + dLat,
                                      longitude: c.longitude + dLon)
    }

    /// 迭代逼近的反向转换，误差 < 1 米，画图足够
    static func toWGS84(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard enabled, !outOfChina(c) else { return c }
        var w = c
        for _ in 0..<3 {
            let g = fromWGS84(w)
            w.latitude += c.latitude - g.latitude
            w.longitude += c.longitude - g.longitude
        }
        return w
    }

    private static func outOfChina(_ c: CLLocationCoordinate2D) -> Bool {
        c.longitude < 72.004 || c.longitude > 137.8347 ||
        c.latitude < 0.8293 || c.latitude > 55.8271
    }

    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}
