import CoreLocation
import Foundation
import MapKit

// ============================================================
//  路线数据源抽象：Apple MapKit / 高德 Web 服务
//  两条路最后都产出 PlannedRoute，后面的跟踪、打包、BLE 完全复用
// ============================================================

struct Place: Identifiable {
    let id = UUID()
    var name: String
    var address: String
    var coordinate: CLLocationCoordinate2D
}

struct PlannedStep {
    var instruction: String
    var road: String
    var maneuver: Maneuver
    var distance: Double
    var end: CLLocationCoordinate2D
}

struct PlannedRoute {
    var coords: [CLLocationCoordinate2D]
    var steps: [PlannedStep]
    var distance: Double
    var time: Double
}

enum RouteSource: String, CaseIterable, Identifiable {
    case apple = "Apple 地图"
    case amap  = "高德"

    var id: String { rawValue }
}

// ============================================================
//  高德 Web 服务 API（不是 iOS SDK，不需要绑定 Bundle ID）
//  注册：https://console.amap.com → 应用管理 → 创建应用
//        → 添加 Key → 服务平台选「Web服务」
// ============================================================

enum AmapService {
    static let keyDefaultsKey = "amap_web_key"

    static var key: String {
        get { UserDefaults.standard.string(forKey: keyDefaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                        forKey: keyDefaultsKey) }
    }

    static var hasKey: Bool { !key.isEmpty }

    // MARK: - POI 搜索

    static func search(_ keyword: String, near: CLLocationCoordinate2D?,
                       completion: @escaping ([Place]) -> Void) {
        guard hasKey else { completion([]); return }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "keywords", value: keyword),
            URLQueryItem(name: "offset", value: "10"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "extensions", value: "base"),
        ]
        if let c = near {
            items.append(URLQueryItem(name: "location", value: "\(c.longitude),\(c.latitude)"))
            items.append(URLQueryItem(name: "radius", value: "50000"))
        }

        request(path: "/v3/place/text", items: items) { obj in
            guard let obj,
                  let pois = obj["pois"] as? [[String: Any]] else {
                completion([])
                return
            }
            var out: [Place] = []
            for p in pois {
                guard let name = p["name"] as? String,
                      let loc = p["location"] as? String,
                      let coord = parseLocation(loc) else { continue }
                var address = ""
                if let a = p["address"] as? String { address = a }
                out.append(Place(name: name, address: address, coordinate: coord))
            }
            completion(out)
        }
    }

    // MARK: - 驾车路径规划

    static func drive(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
                      completion: @escaping (PlannedRoute?) -> Void) {
        guard hasKey else { completion(nil); return }

        let items: [URLQueryItem] = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "origin", value: "\(origin.longitude),\(origin.latitude)"),
            URLQueryItem(name: "destination", value: "\(destination.longitude),\(destination.latitude)"),
            URLQueryItem(name: "extensions", value: "all"),
            URLQueryItem(name: "strategy", value: "0"),   // 速度优先
        ]

        request(path: "/v3/direction/driving", items: items) { obj in
            guard let obj,
                  let route = obj["route"] as? [String: Any],
                  let paths = route["paths"] as? [[String: Any]],
                  let path = paths.first,
                  let steps = path["steps"] as? [[String: Any]],
                  !steps.isEmpty else {
                completion(nil)
                return
            }

            var coords: [CLLocationCoordinate2D] = []
            var plannedSteps: [PlannedStep] = []
            var stepDistanceSum = 0.0

            for (i, raw) in steps.enumerated() {
                let isLast = (i == steps.count - 1)
                let action = (raw["action"] as? String) ?? ""
                let assistant = (raw["assistant_action"] as? String) ?? ""
                let instruction = (raw["instruction"] as? String) ?? ""
                var road = (raw["road"] as? String) ?? ""
                if road.isEmpty { road = instruction }

                let dist = Double((raw["distance"] as? String) ?? "0") ?? 0
                stepDistanceSum += dist

                var stepCoords: [CLLocationCoordinate2D] = []
                if let line = raw["polyline"] as? String {
                    for pair in line.split(separator: ";") {
                        if let c = parseLocation(String(pair)) { stepCoords.append(c) }
                    }
                }

                if !stepCoords.isEmpty {
                    if let last = coords.last,
                       distance(last, stepCoords[0]) < 1.0, stepCoords.count > 1 {
                        coords.append(contentsOf: stepCoords.dropFirst())
                    } else {
                        coords.append(contentsOf: stepCoords)
                    }
                }

                let end = stepCoords.last ?? coords.last ?? origin
                let maneuver = mapAction(action: action, assistant: assistant,
                                         instruction: instruction, isLast: isLast)
                plannedSteps.append(PlannedStep(instruction: instruction, road: road,
                                                maneuver: maneuver, distance: dist, end: end))
            }

            guard coords.count >= 2 else { completion(nil); return }

            let total = Double((path["distance"] as? String) ?? "") ?? stepDistanceSum
            let duration = Double((path["duration"] as? String) ?? "") ?? (total / 12.0)

            // 步进里程与折线可能略有出入，按比例对齐到总里程
            let sum = plannedSteps.reduce(0.0) { $0 + $1.distance }
            if sum > 1, total > 0, abs(sum - total) > 5 {
                let scale = total / sum
                for i in plannedSteps.indices { plannedSteps[i].distance *= scale }
            }

            completion(PlannedRoute(coords: coords, steps: plannedSteps,
                                    distance: total, time: duration))
        }
    }

    // MARK: - 动作映射

    private static func mapAction(action: String, assistant: String,
                                  instruction: String, isLast: Bool) -> Maneuver {
        if isLast { return .arrive }
        let s = action + assistant + instruction

        if s.contains("环岛") { return .roundabout }
        if s.contains("掉头") { return .uturn }
        if s.contains("左后方") { return .sharpLeft }
        if s.contains("右后方") { return .sharpRight }
        if s.contains("左前方") || s.contains("靠左") { return .slightLeft }
        if s.contains("右前方") || s.contains("靠右") { return .slightRight }
        if s.contains("匝道") { return .ramp }
        if s.contains("汇入") || s.contains("进入主路") { return .merge }
        if s.contains("左转") { return .left }
        if s.contains("右转") { return .right }
        if s.contains("直行") || s.contains("继续") { return .straight }
        return .straight
    }

    // MARK: - 网络

    private static func request(path: String, items: [URLQueryItem],
                                completion: @escaping ([String: Any]?) -> Void) {
        var comps = URLComponents(string: "https://restapi.amap.com" + path)
        comps?.queryItems = items
        guard let url = comps?.url else { completion(nil); return }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { data, _, _ in
            var obj: [String: Any]?
            if let data,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let status = json["status"] as? String, status == "1" {
                    obj = json
                } else {
                    let info = (json["info"] as? String) ?? "unknown"
                    print("[amap] error: \(info)")
                }
            }
            DispatchQueue.main.async { completion(obj) }
        }.resume()
    }

    private static func parseLocation(_ s: String) -> CLLocationCoordinate2D? {
        let parts = s.split(separator: ",")
        guard parts.count == 2,
              let lon = Double(parts[0]), let lat = Double(parts[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
