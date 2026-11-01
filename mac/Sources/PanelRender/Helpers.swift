// T2：双层绘制用的小工具：稳定帧判定、帧率换算（纯函数，方便测试）。
import PanelCore

extension Frame {
    /// 稳定帧：各路不透明度（含整屏亮度 dim）全部到位。
    /// 双层绘制时这种帧可以只重画动态层（静态层缓存）。
    public var isSettled: Bool {
        centerAlpha >= 0.999 && statsAlpha >= 0.999 && stripAlpha >= 0.999
            && valueAlpha >= 0.999 && ghostAlpha >= 0.999 && ticksAlpha >= 0.999
            && trackAlpha >= 0.999 && notchAlpha >= 0.999 && dim >= 0.999
    }
}

/// 帧率换算成重画间隔（毫秒）：正在淡入时固定 33，其余按配置帧率
/// 钳制在每秒 1～60 帧（NaN 按 10fps 算），最快 16 毫秒。
public func frameIntervalMs(fps: Double, fadingIn: Bool) -> Int {
    if fadingIn { return 33 }
    var f = fps
    if f.isNaN { f = 10.0 }
    f = max(1.0, min(60.0, f))
    // 向下取整：60fps 要得到 16 毫秒（round 会得 17）
    return max(16, Int(1000.0 / f))
}