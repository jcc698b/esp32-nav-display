import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var link = NavLink()
    @StateObject private var engine = NavigationEngine()

    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searching = false
    @State private var selected: Place?
    @State private var errorText: String?
    @State private var simulate = false
    @AppStorage("amap_web_key") private var amapKey = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    connectionCard
                    if engine.isNavigating || engine.arrived {
                        liveCard
                    } else {
                        sourceCard
                        destinationCard
                        routeCard
                    }
                    footer
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("NavDisplay")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                UIDevice.current.isBatteryMonitoringEnabled = true
                AmapService.key = amapKey
                let service = link
                engine.onPacket = { packet in service.send(packet) }
                engine.onPosition = { data in service.sendRaw(data) }
                engine.onMapBlob = { blob, lines, center in
                    service.sendMap(MapFrame.frames(blob: blob, lineCount: lines, ref: center))
                }
                engine.requestPermission()
                link.reconnect()
            }
            .onChange(of: amapKey) { value in
                AmapService.key = value
            }
            .onChange(of: engine.routeSource) { _ in
                results = []
                errorText = nil
            }
        }
    }

    // MARK: - 数据源

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("路线与搜索").font(.headline)

            Picker("数据源", selection: $engine.routeSource) {
                ForEach(RouteSource.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)

            if engine.routeSource == .amap {
                TextField("粘贴高德 Web 服务 Key", text: $amapKey)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text(AmapService.hasKey
                     ? "已配置：POI 和转向使用高德"
                     : "高德开放平台 → 应用管理 → 添加 Key，服务平台选「Web服务」")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Apple 地图：无需 Key；转向靠几何判断，POI 覆盖一般")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    // MARK: - 连接状态

    private var connectionCard: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(link.state == .ready ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(link.state.text).font(.subheadline.weight(.semibold))
                if link.state == .ready {
                    Text(link.deviceName + (link.firmware.isEmpty ? "" : " · 固件 " + link.firmware))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("给 ESP32 上电后会自动搜索")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if link.state == .ready {
                Text("\(link.packetsSent) 包")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Button("搜索") { link.reconnect() }
                    .buttonStyle(.bordered)
            }
        }
        .card()
    }

    // MARK: - 目的地搜索

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("目的地").font(.headline)

            HStack(spacing: 8) {
                TextField("搜索地点，例如：北京南站", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit(search)
                Button {
                    search()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(searching)
            }

            if searching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("搜索中…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let errorText = errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            ForEach(Array(results.enumerated()), id: \.offset) { idx, item in
                Button {
                    selected = item
                    query = item.name
                    results = []
                    errorText = nil
                    engine.plan(to: item)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.subheadline)
                        Text(item.address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if idx < results.count - 1 { Divider() }
            }
        }
        .card()
    }

    // MARK: - 路线摘要

    @ViewBuilder
    private var routeCard: some View {
        if engine.planning {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在规划路线…").font(.subheadline)
            }
            .card()
        } else if engine.hasRoute {
            VStack(alignment: .leading, spacing: 12) {
                if let selected = selected {
                    Text(selected.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 18) {
                    Label(fmtDist(engine.plannedDistance), systemImage: "road.lanes")
                    Label(fmtTime(engine.plannedTime), systemImage: "clock")
                }
                .font(.subheadline)

                Toggle("模拟导航（坐在家里测试）", isOn: $simulate)

                Button {
                    engine.start(simulate: simulate)
                } label: {
                    Label("开始导航", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if let e = engine.planError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            }
            .card()
        }
    }

    // MARK: - 导航中

    private var liveCard: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: engine.arrived ? "flag.checkered" : engine.currentManeuver.sfSymbol)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.green)
                    .frame(width: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.arrived ? "已到达" : fmtDist(engine.distanceToManeuver))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(engine.arrived
                         ? (selected?.name ?? "")
                         : (engine.currentRoad.isEmpty ? engine.currentManeuver.zh : engine.currentRoad))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            HStack(spacing: 0) {
                stat("到达", engine.etaText)
                Divider().frame(height: 26)
                stat("剩余", fmtDist(engine.remainingDistance))
                Divider().frame(height: 26)
                stat("还需", fmtTime(engine.remainingTime))
            }

            if engine.offRoute {
                Label("已偏离路线，请返回原路线", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                if link.mapBusy {
                    ProgressView().scaleEffect(0.7)
                }
                Text(engine.mapStatus.isEmpty ? "地图：等待数据" : engine.mapStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    engine.stop()
                } label: {
                    Text("结束导航").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    engine.toggleSimulation()
                } label: {
                    Text(engine.isSimulating ? "切回真实定位" : "模拟模式")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .card()
    }

    private var footer: some View {
        Text("提示：iPhone 不向第三方开放系统级导航数据，所以路线和转向由本 App 自己计算，再通过 BLE 发给副屏。导航时请保持 App 在前台（已自动禁止息屏）。")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    // MARK: - 逻辑

    private func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true
        errorText = nil

        engine.searchPlaces(q) { places in
            searching = false
            results = places
            if places.isEmpty {
                errorText = "没有搜到结果，换个关键词试试"
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func fmtDist(_ meters: CLLocationDistance) -> String {
        guard meters >= 0, meters.isFinite else { return "--" }
        if meters < 1000 { return "\(Int(meters.rounded())) 米" }
        return String(format: "%.1f 公里", meters / 1000)
    }

    private func fmtTime(_ seconds: TimeInterval) -> String {
        guard seconds > 0, seconds.isFinite else { return "--" }
        let m = Int(seconds / 60)
        if m < 60 { return "\(max(1, m)) 分钟" }
        return "\(m / 60) 小时 \(m % 60) 分"
    }
}

// MARK: - 卡片样式

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

private extension View {
    func card() -> some View { modifier(CardBackground()) }
}

#Preview {
    ContentView()
}
