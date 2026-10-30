// 入口：命令行参数、单实例、菜单栏 app 的启动；离屏截图（--snapshot / --snapshot-all）。
import AppKit
import Foundation
import ImageIO
import PanelCore
import PanelRender
import UniformTypeIdentifiers

let usage = """
用法：
  TFPanel                                      启动菜单栏 app（副屏上全屏显示仪表盘）
  TFPanel --window                             启动 app，另外在主屏上开一个预览窗口
  TFPanel --no-mode-switch                     启动 app，这次运行不切副屏的显示模式
  TFPanel --capture <目录>                     收到 SIGUSR1 时把当前画面画成 PNG 写到 <目录>/capture-<序号>.png
  TFPanel --snapshot <样例.json> <out.png>     不启动 app：把一个指标样例画成 960×640 的 PNG
  TFPanel --snapshot-all <样例目录> <输出目录>  不启动 app：样例目录下每个 .json 各画一张
"""

let args = CommandLine.arguments

// --snapshot <样例.json> <out.png>：不启动 app
if args.count >= 2, args[1] == "--snapshot" {
    guard args.count >= 4 else { print(usage); exit(1) }
    let jsonPath = args[2]
    let outPath = args[3]
    guard let data = FileManager.default.contents(atPath: jsonPath),
          let snapshot = JSON.parse(data) else {
        print("读取样例失败：\(jsonPath)")
        exit(1)
    }
    let view = ViewModel(config: Config()).update(snapshot, now: 0)
    guard Renderer().renderPNG(view: view, path: outPath) else {
        print("写 PNG 失败：\(outPath)")
        exit(1)
    }
    exit(0)
}

// --snapshot-all <样例目录> <输出目录>：不启动 app
if args.count >= 2, args[1] == "--snapshot-all" {
    guard args.count >= 4 else { print(usage); exit(1) }
    let inDir = args[2]
    let outDir = args[3]
    let fm = FileManager.default
    let names = ((try? fm.contentsOfDirectory(atPath: inDir)) ?? [])
        .filter { $0.hasSuffix(".json") }
        .sorted()
    try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let viewModel = ViewModel(config: Config())
    let renderer = Renderer()
    for name in names {
        guard let data = fm.contents(atPath: (inDir as NSString).appendingPathComponent(name)),
              let snapshot = JSON.parse(data) else {
            print("读取样例失败：\(name)")
            exit(1)
        }
        let outPath = (outDir as NSString).appendingPathComponent(String(name.dropLast(5)) + ".png")
        guard renderer.renderPNG(view: viewModel.update(snapshot, now: 0), path: outPath) else {
            print("写 PNG 失败：\(outPath)")
            exit(1)
        }
    }
    exit(0)
}

// 启动 app 的参数（前三个可以一起用；只影响本次运行，不写回设置）
var showWindow = false
var noModeSwitch = false
var captureDir: String?
var i = 1
while i < args.count {
    switch args[i] {
    case "--window":
        showWindow = true
        i += 1
    case "--no-mode-switch":
        noModeSwitch = true
        i += 1
    case "--capture":
        guard i + 1 < args.count else { print(usage); exit(1) }
        captureDir = args[i + 1]
        i += 2
    default:
        print(usage)
        exit(1)
    }
}

// 只开一个：从 .app 包运行时，已有别的进程在跑就退出
if let bundleID = Bundle.main.bundleIdentifier {
    let me = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != me }
    if !others.isEmpty {
        Log.write("已有 TFPanel 在运行（进程 \(others[0].processIdentifier)），本次退出")
        exit(0)
    }
}

/// 菜单栏 app 的委托：建控制器、状态菜单，按需开预览窗口、注册截图信号。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: AppController
    var statusMenu: StatusMenu?
    private let showWindow: Bool
    private let captureDir: String?
    private var captureSource: DispatchSourceProtocol?
    private var captureCount = 1        // 截图序号（capture-1.png、capture-2.png……）

    init(showWindow: Bool, noModeSwitch: Bool, captureDir: String?) {
        self.controller = AppController(noModeSwitch: noModeSwitch)
        self.showWindow = showWindow
        self.captureDir = captureDir
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        statusMenu = StatusMenu(controller: controller)
        if showWindow { controller.screens.showPreview() }
        if let dir = captureDir { registerCaptureSignal(dir: dir) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureSource?.cancel()
        controller.stop()
    }

    /// SIGUSR1 → 把当前画面截图（先忽略信号，再用 DispatchSource 在主队列处理）。
    private func registerCaptureSignal(dir: String) {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.captureOne(to: dir)
            }
        }
        source.resume()
        captureSource = source
    }

    /// 在主线程上把当前 View 画成 PNG（静止帧）。
    private func captureOne(to dir: String) {
        guard let view = controller.view else {
            Log.write("截图跳过：还没有画面")
            return
        }
        guard let image = Renderer().makeImage(view: view, frame: Animator.settled(view)) else {
            Log.write("截图失败：无法生成图像")
            return
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("capture-\(captureCount).png")
        captureCount += 1
        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            Log.write("截图失败：无法创建 PNG 写入器")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        if CGImageDestinationFinalize(dest) {
            Log.write("截图已保存：\(path)")
        } else {
            Log.write("截图失败：\(path)")
        }
    }
}

Log.start()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(showWindow: showWindow, noModeSwitch: noModeSwitch, captureDir: captureDir)
app.delegate = delegate
app.run()
