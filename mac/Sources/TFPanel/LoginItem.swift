// 占位：A3 实现（接口约定 9.5）
enum LoginItem {
    static var available: Bool { false }
    static var enabled: Bool { false }
    static func set(_ on: Bool) -> Bool { false }
}
