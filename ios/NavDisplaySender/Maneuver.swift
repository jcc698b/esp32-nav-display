import Foundation

/// 与固件约定一致的转向类型
enum Maneuver: String, CaseIterable {
    case none
    case depart
    case straight
    case slightLeft  = "slight-left"
    case left
    case sharpLeft   = "sharp-left"
    case slightRight = "slight-right"
    case right
    case sharpRight  = "sharp-right"
    case uturn
    case roundabout
    case merge
    case fork
    case ramp
    case arrive

    var zh: String {
        switch self {
        case .none:        return "—"
        case .depart:      return "出发"
        case .straight:    return "直行"
        case .slightLeft:  return "稍向左"
        case .left:        return "左转"
        case .sharpLeft:   return "急左转"
        case .slightRight: return "稍向右"
        case .right:       return "右转"
        case .sharpRight:  return "急右转"
        case .uturn:       return "掉头"
        case .roundabout:  return "环岛"
        case .merge:       return "汇入"
        case .fork:        return "岔路"
        case .ramp:        return "匝道"
        case .arrive:      return "到达"
        }
    }

    var sfSymbol: String {
        switch self {
        case .none, .straight, .depart: return "arrow.up"
        case .slightLeft:  return "arrow.up.left"
        case .left:        return "arrow.turn.up.left"
        case .sharpLeft:   return "arrow.uturn.left"
        case .slightRight: return "arrow.up.right"
        case .right:       return "arrow.turn.up.right"
        case .sharpRight:  return "arrow.uturn.right"
        case .uturn:       return "arrow.uturn.down"
        case .roundabout:  return "arrow.clockwise"
        case .merge:       return "arrow.merge"
        case .fork:        return "arrow.triangle.branch"
        case .ramp:        return "arrow.up.forward"
        case .arrive:      return "flag.checkered"
        }
    }

    /// 和固件 map_nav.h 的枚举顺序一致
    var code: UInt8 {
        switch self {
        case .none:        return 0
        case .depart:      return 1
        case .straight:    return 2
        case .slightLeft:  return 3
        case .left:        return 4
        case .sharpLeft:   return 5
        case .slightRight: return 6
        case .right:       return 7
        case .sharpRight:  return 8
        case .uturn:       return 9
        case .roundabout:  return 10
        case .merge:       return 11
        case .fork:        return 12
        case .ramp:        return 13
        case .arrive:      return 14
        }
    }
}
