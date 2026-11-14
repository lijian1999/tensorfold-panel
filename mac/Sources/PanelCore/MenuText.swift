// 菜单栏里的文字规则（纯逻辑，供 TFPanel 的菜单用）。
import Foundation

/// 菜单里引擎那一行。engine 是设置里的引擎值（"omlx" / "tensorfold"）。
public func engineMenuText(issue: EngineIssue, address: String, engine: String) -> String {
    let name = engine == "tensorfold" ? "TensorFold" : "oMLX"
    switch issue {
    case .none:
        return "引擎：\(name) · \(address)"
    case .unreachable:
        return "引擎：未连接"
    case .notOmlx, .needsKey, .notTensorfold, .needsKeyTensorfold:
        return "引擎：" + issue.message!
    }
}

/// 时区子菜单的三项标题，顺序同 ZoneChoice.allCases。
public func zoneMenuTitles(systemZone: String) -> [String] {
    ["跟随系统（\(zoneDisplayName(systemZone))）", "北京时间", "太平洋时间"]
}

/// 菜单里“费用单价…”那一项的标题。当前模型没价（用户价或内置 DeepSeek 官方价）时提示未填。
public func priceMenuTitle(currentModel: String?, prices: [String: ModelPrice],
                           currency: String = "$") -> String {
    if let m = currentModel, !m.isEmpty,
       priceForUse(model: m, prices: prices, currency: currency) == nil {
        return "费用单价…（当前模型未填）"
    }
    return "费用单价…"
}
