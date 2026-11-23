import Foundation

/// 与 ESP32 之间约定的数据包，字段含义见 docs/protocol.md
struct NavPacket: Codable {
    var v: Int = 1
    var st: String = "idle"     // idle | nav | arr
    var mn: String = "none"     // 当前动作
    var d: Int = -1             // 到本动作的距离（米）
    var nx: String = "none"     // 下一个动作
    var nd: Int = -1            // 到下一个动作的距离（米）
    var rd: String = ""         // 道路 / 指令
    var eta: String = ""        // 预计到达 "18:42"
    var rem: Int = -1           // 剩余总里程（米）
    var rt: Int = -1            // 剩余时间（秒）
    var spd: Int = -1           // 车速 km/h
    var bat: Int = -1           // 手机电量 %

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    /// 编码成 UTF-8 JSON，并保证不超过 BLE 单包长度
    func encoded(maxBytes: Int) -> Data {
        var copy = self
        var data = (try? Self.encoder.encode(copy)) ?? Data()
        guard maxBytes > 0 else { return data }
        // 超长时逐步裁剪道路名（中文一个字 3 字节）
        while data.count > maxBytes && !copy.rd.isEmpty {
            copy.rd = String(copy.rd.dropLast())
            data = (try? Self.encoder.encode(copy)) ?? Data()
        }
        return data
    }
}
