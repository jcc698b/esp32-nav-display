import CoreBluetooth
import Foundation

/// BLE 主机（Central）：扫描并连接 ESP32 导航屏，把 JSON 写到 NAV 特征值
final class NavLink: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "4E415647-5053-4C31-9000-000000000001")
    static let navUUID     = CBUUID(string: "4E415647-5053-4C31-9000-000000000002")
    static let statusUUID  = CBUUID(string: "4E415647-5053-4C31-9000-000000000003")

    enum State: Equatable {
        case bluetoothOff
        case idle
        case scanning
        case connecting
        case ready

        var text: String {
            switch self {
            case .bluetoothOff: return "请打开手机蓝牙"
            case .idle:         return "未连接"
            case .scanning:     return "正在搜索设备…"
            case .connecting:   return "正在连接…"
            case .ready:        return "已连接"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var deviceName: String = ""
    @Published private(set) var firmware: String = ""
    @Published private(set) var packetsSent: Int = 0
    @Published private(set) var lastError: String = ""
    @Published private(set) var mapBusy = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var navChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?

    private var pending: [Data] = []
    private var reconnectWork: DispatchWorkItem?
    private var mapQueue: [Data] = []
    private var mapTimer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 对外接口

    func send(_ packet: NavPacket) {
        guard let peripheral = peripheral, let navChar = navChar else { return }
        let maxLen = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let data = packet.encoded(maxBytes: max(20, maxLen))
        write(data, to: navChar, on: peripheral)
    }

    /// 直接发二进制帧（位置包 / 地图帧）
    func sendRaw(_ data: Data) {
        guard let peripheral = peripheral, let navChar = navChar else { return }
        write(data, to: navChar, on: peripheral)
    }

    /// 分帧发送地图，内部按 BLE 流控节流
    func sendMap(_ frames: [Data]) {
        guard !frames.isEmpty, navChar != nil else { return }
        mapQueue = frames
        mapBusy = true
        if mapTimer == nil {
            mapTimer = Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { [weak self] _ in
                self?.pumpMap()
            }
        }
    }

    func reconnect() {
        reconnectWork?.cancel()
        guard let p = peripheral else {
            startScan()
            return
        }
        central.cancelPeripheralConnection(p)
        startScan()
    }

    // MARK: - 内部

    private func startScan() {
        guard central.state == .poweredOn else { return }
        central.stopScan()
        stopMap()
        peripheral = nil
        navChar = nil
        statusChar = nil
        state = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    private func write(_ data: Data, to char: CBCharacteristic, on peripheral: CBPeripheral) {
        if char.properties.contains(.writeWithoutResponse) {
            if peripheral.canSendWriteWithoutResponse {
                peripheral.writeValue(data, for: char, type: .withoutResponse)
                packetsSent += 1
            } else if pending.count < 4 {
                pending.append(data)
            }
        } else {
            peripheral.writeValue(data, for: char, type: .withResponse)
            packetsSent += 1
        }
    }

    private func flush() {
        guard let peripheral = peripheral, let navChar = navChar else { return }
        while peripheral.canSendWriteWithoutResponse, !pending.isEmpty {
            let d = pending.removeFirst()
            peripheral.writeValue(d, for: navChar, type: .withoutResponse)
            packetsSent += 1
        }
    }

    private func pumpMap() {
        guard let peripheral = peripheral, let navChar = navChar else { stopMap(); return }
        guard !mapQueue.isEmpty else { stopMap(); return }
        if peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(mapQueue.removeFirst(), for: navChar, type: .withoutResponse)
            packetsSent += 1
        }
    }

    private func stopMap() {
        mapTimer?.invalidate()
        mapTimer = nil
        mapQueue.removeAll()
        mapBusy = false
    }

    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startScan() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

// MARK: - CBCentralManagerDelegate

extension NavLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScan()
        case .poweredOff, .unauthorized, .unsupported:
            state = .bluetoothOff
        default:
            state = .idle
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        deviceName = peripheral.name ?? "ESP32-Navi"
        state = .connecting
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connecting
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        lastError = error?.localizedDescription ?? "连接失败"
        self.peripheral = nil
        state = .idle
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        stopMap()
        navChar = nil
        statusChar = nil
        self.peripheral = nil
        state = .idle
        deviceName = ""
        firmware = ""
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension NavLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.navUUID, Self.statusUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }
        for c in chars {
            if c.uuid == Self.navUUID { navChar = c }
            if c.uuid == Self.statusUUID {
                statusChar = c
                peripheral.setNotifyValue(true, for: c)
                peripheral.readValue(for: c)
            }
        }
        if navChar != nil {
            state = .ready
            lastError = ""
        } else {
            lastError = "设备上没有找到导航特征值"
            state = .idle
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.statusUUID,
              let data = characteristic.value,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let fw = obj["fw"] as? String { firmware = fw }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flush()
    }
}
