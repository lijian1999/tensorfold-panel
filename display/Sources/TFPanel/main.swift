import AppKit
import Foundation
import PanelCore

/// 截一张：`--snapshot <fixture.json | offline> <out.png>`
@MainActor
func runSnapshot(_ source: String, out: String) throws {
    let tracker = try Snapshot.makeTracker(source)
    let now = source == "offline" ? 143.0 : 100.0
    let image = Snapshot.render(tracker, now: now, scale: 2)
    try Snapshot.save(image, to: URL(fileURLWithPath: out))
}

/// 对 Fixtures 下每个 JSON 以及 offline 各出一张：<名字>.png
@MainActor
func runSnapshotAll(_ dir: String) throws {
    let outDir = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let fixtures = Snapshot.fixturesDir()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: fixtures.path))?.sorted() ?? []
    for name in names where name.hasSuffix(".json") {
        try runSnapshot(fixtures.appendingPathComponent(name).path,
                        out: outDir.appendingPathComponent(String(name.dropLast(5))).appendingPathExtension("png").path)
    }
    try runSnapshot("offline", out: outDir.appendingPathComponent("offline.png").path)
}

let usage = """
用法：
  TFPanel                                  启动窗口程序（副屏上全屏显示仪表盘）
  TFPanel --metrics-url <url>             覆盖指标地址（默认 http://127.0.0.1:8081/metrics）
  TFPanel --screen <名字>                 覆盖副屏名（默认取设置里的值，初始 TYPE-C）
  TFPanel --debug-capture <目录>          收到 SIGUSR1 时把副屏画面截图到 <目录>/capture-<序号>.png
  TFPanel --snapshot <fixture.json | offline> <out.png>   离屏截一张 960×640 PNG
  TFPanel --snapshot-all <目录>           对 Fixtures 下每个 JSON 及 offline 各出一张
"""

let args = CommandLine.arguments
if args.count >= 2 && args[1] == "--snapshot" {
    do {
        if args.count >= 4 {
            try runSnapshot(args[2], out: args[3])
        } else {
            print(usage)
            exit(1)
        }
    } catch {
        print("截图失败：\(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}
if args.count >= 2 && args[1] == "--snapshot-all" {
    do {
        if args.count >= 3 {
            try runSnapshotAll(args[2])
        } else {
            print(usage)
            exit(1)
        }
    } catch {
        print("截图失败：\(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

// 启动窗口程序：解析可选参数（只影响本次运行，不写回设置）
var metricsURL: String?
var screenName: String?
var debugCapture: String?
var i = 1
while i < args.count {
    if args[i] == "--metrics-url", i + 1 < args.count {
        metricsURL = args[i + 1]
        i += 2
    } else if args[i] == "--screen", i + 1 < args.count {
        screenName = args[i + 1]
        i += 2
    } else if args[i] == "--debug-capture", i + 1 < args.count {
        debugCapture = args[i + 1]
        i += 2
    } else {
        print(usage)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate(metricsURL: metricsURL, screenName: screenName, debugCapture: debugCapture)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
