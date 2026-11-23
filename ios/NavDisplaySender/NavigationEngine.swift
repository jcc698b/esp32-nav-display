import CoreLocation
import Foundation
import MapKit
import UIKit

/// 路线 + 定位 + 沿路线进度推算，把结果打包成 NavPacket 发出去。
final class NavigationEngine: NSObject, ObservableObject {

    // MARK: - 对外状态
    @Published private(set) var isNavigating = false
    @Published private(set) var isSimulating = false
    @Published private(set) var arrived = false
    @Published private(set) var planning = false
    @Published private(set) var planError: String?
    @Published private(set) var plannedDistance: CLLocationDistance = 0
    @Published private(set) var plannedTime: TimeInterval = 0
    @Published private(set) var hasRoute = false

    @Published private(set) var currentManeuver: Maneuver = .none
    @Published private(set) var nextManeuver: Maneuver = .none
    @Published private(set) var currentRoad: String = ""
    @Published private(set) var distanceToManeuver: CLLocationDistance = 0
    @Published private(set) var nextDistance: CLLocationDistance = 0
    @Published private(set) var remainingDistance: CLLocationDistance = 0
    @Published private(set) var remainingTime: TimeInterval = 0
    @Published private(set) var etaText: String = "--:--"
    @Published private(set) var speedKmh: Int = 0
    @Published private(set) var offRoute = false
    @Published private(set) var userCoordinate: CLLocationCoordinate2D?
    @Published private(set) var mapStatus: String = ""
    @Published var routeSource: RouteSource = .apple

    /// 每个数据包生成时回调（主线程）
    var onPacket: ((NavPacket) -> Void)?
    var onPosition: ((Data) -> Void)?
    var onMapBlob: ((Data, Int, CLLocationCoordinate2D) -> Void)?

    // MARK: - 私有
    private struct RouteModel {
        let total: Double
        let coords: [CLLocationCoordinate2D]
        let cum: [Double]
        let stepEnds: [Double]
        let maneuvers: [Maneuver]
        let roads: [String]
        let turnPoints: [CLLocationCoordinate2D]
        let expectedTime: TimeInterval
    }

    private let locationManager = CLLocationManager()
    private var planned: PlannedRoute?
    private var model: RouteModel?
    private var traveled: Double = 0
    private var lastSpeed: Double = 0
    private var sendTimer: Timer?
    private var simTimer: Timer?
    private var arrivedTimer: Timer?
    private var offRouteSince: Date?
    private var currentStepIndex = 0
    private var lastCourse: Double = 0
    private var lastMapCenter: CLLocationCoordinate2D?
    private var lastMapAt = Date.distantPast
    private var mapBusy = false

    private static let etaFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 3
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - 权限 & 定位

    func requestPermission() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
        default:
            break
        }
    }

    // MARK: - 规划路线

    func plan(to place: Place, completion: ((Bool) -> Void)? = nil) {
        guard !planning else { return }
        planning = true
        planError = nil
        hasRoute = false

        // 高德 Web 服务
        if routeSource == .amap, AmapService.hasKey {
            guard let origin = userCoordinate else {
                planning = false
                planError = "正在获取定位，请稍后再试"
                completion?(false)
                return
            }
            AmapService.drive(from: origin, to: place.coordinate) { [weak self] result in
                guard let self else { return }
                self.planning = false
                if let result {
                    self.apply(result)
                    completion?(true)
                } else {
                    self.planError = "高德算路失败（检查 Key / 配额 / 网络）"
                    completion?(false)
                }
            }
            return
        }

        // Apple MapKit
        let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        item.name = place.name

        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = item
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        MKDirections(request: request).calculate { [weak self] response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.planning = false
                if let route = response?.routes.first {
                    self.apply(self.planFromMKRoute(route))
                    completion?(true)
                } else {
                    self.planError = error?.localizedDescription ?? "没有找到可行路线"
                    completion?(false)
                }
            }
        }
    }

    private func apply(_ plan: PlannedRoute) {
        planned = plan
        plannedDistance = plan.distance
        plannedTime = plan.time
        hasRoute = true
        planError = nil
    }

    func searchPlaces(_ query: String, completion: @escaping ([Place]) -> Void) {
        if routeSource == .amap, AmapService.hasKey {
            AmapService.search(query, near: userCoordinate, completion: completion)
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let c = userCoordinate {
            request.region = MKCoordinateRegion(center: c,
                                                latitudinalMeters: 50_000,
                                                longitudinalMeters: 50_000)
        }
        MKLocalSearch(request: request).start { response, _ in
            let places = (response?.mapItems ?? []).map {
                Place(name: $0.name ?? "未命名地点",
                      address: $0.placemark.title ?? "",
                      coordinate: $0.placemark.coordinate)
            }
            DispatchQueue.main.async { completion(places) }
        }
    }

    // MARK: - 开始 / 结束

    func start(simulate: Bool) {
        guard let plan = planned, let built = buildModel(plan) else {
            planError = "请先选择目的地并规划路线"
            return
        }
        stopTimers()
        planError = nil

        model = built
        traveled = 0
        lastSpeed = 0
        arrived = false
        isNavigating = true
        isSimulating = simulate
        offRoute = false
        offRouteSince = nil
        lastMapCenter = nil
        mapBusy = false
        mapStatus = "准备地图…"
        UIApplication.shared.isIdleTimerDisabled = true

        if simulate {
            locationManager.stopUpdatingLocation()
            startSimulation()
        } else {
            requestPermission()
            locationManager.startUpdatingLocation()
        }

        sendTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateProgress(self.traveled, speed: self.lastSpeed)
        }
        updateProgress(0, speed: 0)
    }

    func stop() {
        stopTimers()
        locationManager.stopUpdatingLocation()
        isNavigating = false
        isSimulating = false
        arrived = false
        offRoute = false
        mapStatus = ""
        lastMapCenter = nil
        mapBusy = false
        UIApplication.shared.isIdleTimerDisabled = false

        var p = NavPacket()
        p.st = "idle"
        p.bat = batteryLevel()
        onPacket?(p)
    }

    func toggleSimulation() {
        guard isNavigating else { return }
        isSimulating.toggle()
        if isSimulating {
            locationManager.stopUpdatingLocation()
            startSimulation()
        } else {
            simTimer?.invalidate()
            simTimer = nil
            requestPermission()
            locationManager.startUpdatingLocation()
        }
    }

    // MARK: - 路线模型

    private func buildModel(_ plan: PlannedRoute) -> RouteModel? {
        let coords = plan.coords
        guard coords.count >= 2 else { return nil }

        var cum: [Double] = [0]
        cum.reserveCapacity(coords.count)
        for i in 1..<coords.count {
            cum.append(cum[i - 1] + distance(coords[i - 1], coords[i]))
        }
        guard let total = cum.last, total > 1 else { return nil }

        var ends: [Double] = []
        var acc: Double = 0
        for step in plan.steps {
            acc += step.distance
            ends.append(acc)
        }
        if ends.isEmpty { ends = [total] }

        // 步进距离之和与折线长度对齐
        if let accTotal = ends.last, accTotal > 1, abs(accTotal - total) > max(5, total * 0.03) {
            let scale = total / accTotal
            ends = ends.map { $0 * scale }
        }
        ends[ends.count - 1] = total

        var maneuvers = plan.steps.map { $0.maneuver }
        var roads = plan.steps.map { $0.road }
        var turnPoints = plan.steps.map { $0.end }
        if maneuvers.isEmpty {
            maneuvers = [.straight]
            roads = ["沿路线行驶"]
        }
        if turnPoints.isEmpty { turnPoints = [coords.last ?? coords[0]] }

        return RouteModel(total: total, coords: coords, cum: cum, stepEnds: ends,
                          maneuvers: maneuvers, roads: roads, turnPoints: turnPoints,
                          expectedTime: plan.time)
    }

    private func planFromMKRoute(_ route: MKRoute) -> PlannedRoute {
        let polyline = route.polyline
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                             count: polyline.pointCount)
        if polyline.pointCount > 0 {
            polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        }

        var steps: [PlannedStep] = []
        for (i, step) in route.steps.enumerated() {
            let end = lastCoordinate(of: step.polyline) ?? coords.last ?? CLLocationCoordinate2D()
            steps.append(PlannedStep(instruction: step.instructions,
                                     road: shortRoad(step.instructions),
                                     maneuver: classify(route: route, index: i),
                                     distance: step.distance,
                                     end: end))
        }
        return PlannedRoute(coords: coords, steps: steps,
                            distance: route.distance, time: route.expectedTravelTime)
    }

    private func lastCoordinate(of polyline: MKPolyline) -> CLLocationCoordinate2D? {
        let n = polyline.pointCount
        guard n > 0 else { return nil }
        var c = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: n)
        polyline.getCoordinates(&c, range: NSRange(location: 0, length: n))
        return c[n - 1]
    }

    /// 用「进入/onto」把指令里的道路名抠出来
    private func shortRoad(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in ["进入", "驶入"] {
            if let r = s.range(of: token) {
                s = String(s[r.upperBound...])
                break
            }
        }
        for token in [" onto ", " on "] {
            if let r = s.range(of: token) {
                s = String(s[r.upperBound...])
                break
            }
        }
        s = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if s.count > 24 { s = String(s.prefix(24)) }
        return s.isEmpty ? "继续直行" : s
    }

    /// 优先用指令关键词，其次用相邻两段路的方位角差
    private func classify(route: MKRoute, index: Int) -> Maneuver {
        let steps = route.steps
        guard index < steps.count else { return .straight }
        if index >= steps.count - 1 { return .arrive }

        let text = steps[index].instructions.lowercased()
        if text.contains("环岛") || text.contains("roundabout") { return .roundabout }
        if text.contains("掉头") || text.contains("u-turn") || text.contains("uturn") { return .uturn }
        if text.contains("匝道") || text.contains("ramp") { return .ramp }
        if text.contains("汇入") || text.contains("merge") { return .merge }
        if text.contains("岔路") || text.contains("fork") || text.contains("keep") { return .fork }
        if index == 0 { return .depart }

        guard let inBearing = bearing(of: steps[index - 1].polyline, atEnd: true),
              let outBearing = bearing(of: steps[index].polyline, atEnd: false) else {
            return .straight
        }
        var delta = (outBearing - inBearing).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }

        switch abs(delta) {
        case ..<12:   return .straight
        case ..<50:   return delta > 0 ? .slightRight : .slightLeft
        case ..<135:  return delta > 0 ? .right : .left
        case ..<165:  return delta > 0 ? .sharpRight : .sharpLeft
        default:      return .uturn
        }
    }

    private func bearing(of polyline: MKPolyline, atEnd: Bool) -> Double? {
        let n = polyline.pointCount
        guard n >= 2 else { return nil }
        var c = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: n)
        polyline.getCoordinates(&c, range: NSRange(location: 0, length: n))
        let a = atEnd ? c[n - 2] : c[0]
        let b = atEnd ? c[n - 1] : c[1]
        let dLat = b.latitude - a.latitude
        let dLon = (b.longitude - a.longitude) * cos(a.latitude * .pi / 180)
        guard abs(dLat) > 1e-9 || abs(dLon) > 1e-9 else { return nil }
        var deg = atan2(dLon, dLat) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    // MARK: - 地图数据

    private func coordinateAt(_ t: Double) -> CLLocationCoordinate2D? {
        guard let model = model, model.coords.count >= 2 else { return nil }
        let c = model.coords
        var i = 0
        while i < model.cum.count - 2 && t > model.cum[i + 1] { i += 1 }
        let span = model.cum[i + 1] - model.cum[i]
        let f = span > 0 ? max(0, min(1, (t - model.cum[i]) / span)) : 0
        let a = c[i], b = c[i + 1]
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                      longitude: a.longitude + (b.longitude - a.longitude) * f)
    }

    private func bearingAt(_ t: Double) -> Double {
        guard let model = model, model.coords.count >= 2 else { return lastCourse }
        let c = model.coords
        var i = 0
        while i < model.cum.count - 2 && t > model.cum[i + 1] { i += 1 }
        let a = c[i], b = c[i + 1]
        let dLat = b.latitude - a.latitude
        let dLon = (b.longitude - a.longitude) * cos(a.latitude * .pi / 180)
        if abs(dLat) < 1e-9 && abs(dLon) < 1e-9 { return lastCourse }
        var deg = atan2(dLon, dLat) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    private func makePositionPacket() -> Data {
        let coord = isSimulating
            ? (coordinateAt(traveled) ?? model?.coords.first ?? CLLocationCoordinate2D())
            : (userCoordinate ?? coordinateAt(traveled) ?? model?.coords.first ?? CLLocationCoordinate2D())
        let heading = isSimulating ? bearingAt(traveled) : lastCourse
        var turnCoord: CLLocationCoordinate2D?
        if let model = model, !model.turnPoints.isEmpty {
            turnCoord = model.turnPoints[min(currentStepIndex, model.turnPoints.count - 1)]
        }
        return MapFrame.position(lat: coord.latitude,
                                 lon: coord.longitude,
                                 headingDeg: heading,
                                 speedKmh: Double(max(0, speedKmh)),
                                 distanceToTurn: distanceToManeuver,
                                 turn: currentManeuver,
                                 arrived: arrived,
                                 turnCoordinate: turnCoord)
    }

    private func refreshMapIfNeeded() {
        guard isNavigating, let model = model else { return }
        guard let center = isSimulating
            ? coordinateAt(traveled)
            : (userCoordinate ?? coordinateAt(traveled)) else { return }

        if let last = lastMapCenter {
            let d = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
            if d < 600 { return }
        }
        if mapBusy || Date().timeIntervalSince(lastMapAt) < 4 { return }

        mapBusy = true
        lastMapAt = Date()
        mapStatus = "加载周边地图…"

        let routeCoords = model.coords
        OSMBasemap.shared.roads(around: center, radius: 1500) { [weak self] roads in
            guard let self else { return }
            let (blob, lines) = MapBlob.build(route: routeCoords, roads: roads, center: center)
            self.mapBusy = false
            self.lastMapCenter = center
            guard !blob.isEmpty else {
                self.mapStatus = roads.isEmpty ? "周边道路不可用" : "地图为空"
                return
            }
            self.mapStatus = "地图 \(blob.count / 1024) KB"
            self.onMapBlob?(blob, lines, center)
        }
    }

    // MARK: - 进度

    /// 把坐标投影到路线上，返回沿线里程和横向偏移
    private func project(_ loc: CLLocationCoordinate2D) -> (traveled: Double, lateral: Double) {
        guard let model = model else { return (traveled, .greatestFiniteMagnitude) }
        let kx = cos(loc.latitude * .pi / 180) * 111_320.0
        let ky = 110_540.0
        var best = (d: Double.greatestFiniteMagnitude, t: 0.0)

        func local(_ c: CLLocationCoordinate2D) -> (Double, Double) {
            ((c.longitude - loc.longitude) * kx, (c.latitude - loc.latitude) * ky)
        }

        for i in 0..<(model.coords.count - 1) {
            let a = local(model.coords[i])
            let b = local(model.coords[i + 1])
            let dx = b.0 - a.0
            let dy = b.1 - a.1
            let len2 = dx * dx + dy * dy
            var t = 0.0
            if len2 > 1e-9 {
                t = max(0, min(1, -(a.0 * dx + a.1 * dy) / len2))
            }
            let px = a.0 + dx * t
            let py = a.1 + dy * t
            let d = sqrt(px * px + py * py)
            if d < best.d {
                best = (d, model.cum[i] + (model.cum[i + 1] - model.cum[i]) * t)
            }
        }
        return (best.t, best.d)
    }

    private func updateProgress(_ distanceAlong: Double, speed: Double) {
        guard let model = model else { return }
        var t = max(0, distanceAlong)
        t = min(t, model.total)

        remainingDistance = max(0, model.total - t)

        let idx = model.stepEnds.firstIndex(where: { t < $0 }) ?? (model.stepEnds.count - 1)
        currentStepIndex = idx
        currentManeuver = model.maneuvers[min(idx, model.maneuvers.count - 1)]
        currentRoad = model.roads[min(idx, model.roads.count - 1)]
        distanceToManeuver = max(0, model.stepEnds[idx] - t)

        if idx + 1 < model.stepEnds.count {
            nextManeuver = model.maneuvers[min(idx + 1, model.maneuvers.count - 1)]
            nextDistance = max(0, model.stepEnds[idx + 1] - t)
        } else {
            nextManeuver = .none
            nextDistance = 0
        }

        let ratio = model.total > 0 ? remainingDistance / model.total : 0
        remainingTime = max(0, model.expectedTime * ratio)
        speedKmh = Int(max(0, speed) * 3.6)

        etaText = Self.etaFormatter.string(from: Date().addingTimeInterval(remainingTime))

        onPacket?(makePacket())
        onPosition?(makePositionPacket())
        refreshMapIfNeeded()

        if remainingDistance < 15 {
            finish()
        }
    }

    private func finish() {
        guard !arrived else { return }
        arrived = true
        isNavigating = false
        simTimer?.invalidate()
        simTimer = nil
        sendTimer?.invalidate()
        sendTimer = nil
        locationManager.stopUpdatingLocation()
        UIApplication.shared.isIdleTimerDisabled = false

        onPacket?(makePacket())

        // 到达后每 2 秒再发一次，避免副屏超时回到等待界面
        arrivedTimer?.invalidate()
        arrivedTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.onPacket?(self.makePacket())
        }
    }

    private func startSimulation() {
        simTimer?.invalidate()
        simTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let model = self.model else { return }
            let v = 13.9  // 50 km/h
            self.traveled = min(model.total, self.traveled + v * 0.25)
            self.lastSpeed = v
            self.updateProgress(self.traveled, speed: v)
        }
    }

    private func stopTimers() {
        sendTimer?.invalidate(); sendTimer = nil
        simTimer?.invalidate(); simTimer = nil
        arrivedTimer?.invalidate(); arrivedTimer = nil
    }

    private func batteryLevel() -> Int {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? -1 : Int(level * 100)
    }

    private func makePacket() -> NavPacket {
        var p = NavPacket()
        p.bat = batteryLevel()

        if arrived {
            p.st = "arr"
            p.mn = Maneuver.arrive.rawValue
            p.d = 0
            p.rd = currentRoad
            p.eta = etaText
            p.rem = 0
            p.rt = 0
            return p
        }
        guard isNavigating else {
            p.st = "idle"
            return p
        }

        p.st = "nav"
        p.mn = currentManeuver.rawValue
        p.d = Int(distanceToManeuver.rounded())
        p.nx = nextManeuver.rawValue
        p.nd = Int(nextDistance.rounded())
        p.rd = currentRoad
        p.eta = etaText
        p.rem = Int(remainingDistance.rounded())
        p.rt = Int(remainingTime.rounded())
        p.spd = speedKmh
        return p
    }

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

// MARK: - CLLocationManagerDelegate

extension NavigationEngine: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        userCoordinate = loc.coordinate
        if loc.course >= 0 { lastCourse = loc.course }

        guard isNavigating, !isSimulating else { return }
        guard loc.horizontalAccuracy < 60 else { return }

        let p = project(loc.coordinate)
        if p.lateral > 70 {
            if offRouteSince == nil { offRouteSince = Date() }
            offRoute = (Date().timeIntervalSince(offRouteSince ?? Date()) > 4)
        } else {
            offRouteSince = nil
            offRoute = false
        }
        guard !offRoute else { return }

        // 只前进不后退，过滤 GPS 抖动
        traveled = max(traveled, p.traveled)
        if loc.speed > 0 { lastSpeed = loc.speed }
        updateProgress(traveled, speed: lastSpeed)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("location error: \(error.localizedDescription)")
    }
}
