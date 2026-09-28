import CoreGraphics
import Foundation
import Testing
import PanelCore

@Suite("DisplayPolicy.pickMode：显示模式选择")
struct PickModeTests {
    @Test("没有匹配 → nil")
    func noMatch() {
        let modes = [
            DisplayPolicy.ModeInfo(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60),
            DisplayPolicy.ModeInfo(width: 1680, height: 1050, pixelWidth: 1680, pixelHeight: 1050, refreshRate: 120),
        ]
        #expect(DisplayPolicy.pickMode(modes) == nil)
    }

    @Test("960×640 但像素 1920×1280（HiDPI）不选")
    func hidpiRejected() {
        let modes = [
            DisplayPolicy.ModeInfo(width: 960, height: 640, pixelWidth: 1920, pixelHeight: 1280, refreshRate: 60),
        ]
        #expect(DisplayPolicy.pickMode(modes) == nil)
    }

    @Test("多个匹配时选刷新率最高的")
    func highestRefresh() {
        let modes = [
            DisplayPolicy.ModeInfo(width: 960, height: 640, pixelWidth: 960, pixelHeight: 640, refreshRate: 60.0),
            DisplayPolicy.ModeInfo(width: 960, height: 640, pixelWidth: 960, pixelHeight: 640, refreshRate: 240.0),
            DisplayPolicy.ModeInfo(width: 960, height: 640, pixelWidth: 960, pixelHeight: 640, refreshRate: 120.0),
        ]
        #expect(DisplayPolicy.pickMode(modes) == 1)
    }

    @Test("唯一匹配 → 0")
    func singleMatch() {
        let modes = [
            DisplayPolicy.ModeInfo(width: 1024, height: 768, pixelWidth: 1024, pixelHeight: 768, refreshRate: 60),
            DisplayPolicy.ModeInfo(width: 960, height: 640, pixelWidth: 960, pixelHeight: 640, refreshRate: 60),
        ]
        #expect(DisplayPolicy.pickMode(modes) == 1)
    }
}

@Suite("DisplayPolicy.fit：缩放与留边")
struct FitTests {
    @Test("960×640 → scale 2、origin (0,0)")
    func native() {
        let f = DisplayPolicy.fit(screenSize: CGSize(width: 960, height: 640))
        #expect(abs(f.scale - 2) < 1e-9)
        #expect(abs(f.origin.x) < 1e-9)
        #expect(abs(f.origin.y) < 1e-9)
    }

    @Test("1920×1080 → scale 3.375、水平居中")
    func larger() {
        let f = DisplayPolicy.fit(screenSize: CGSize(width: 1920, height: 1080))
        #expect(abs(f.scale - 3.375) < 1e-9)
        // 1620 宽 → 左右各留 150；高度正好
        #expect(abs(f.origin.x - 150) < 1e-9)
        #expect(abs(f.origin.y) < 1e-9)
    }

    @Test("480×320 → scale 1")
    func designSize() {
        let f = DisplayPolicy.fit(screenSize: CGSize(width: 480, height: 320))
        #expect(abs(f.scale - 1) < 1e-9)
        #expect(abs(f.origin.x) < 1e-9)
        #expect(abs(f.origin.y) < 1e-9)
    }
}

@Suite("DisplayPolicy.dimmed：调暗")
struct DimmedTests {
    @Test("idle 29 分钟不暗、31 分钟暗")
    func idle() {
        #expect(!DisplayPolicy.dimmed(state: .idle, stateSince: 0, now: 29 * 60))
        #expect(DisplayPolicy.dimmed(state: .idle, stateSince: 0, now: 31 * 60))
    }

    @Test("正好 30 分钟不暗（要「持续超过」）")
    func idleBoundary() {
        #expect(!DisplayPolicy.dimmed(state: .idle, stateSince: 0, now: 30 * 60))
    }

    @Test("offline 31 分钟暗")
    func offline() {
        #expect(DisplayPolicy.dimmed(state: .offline, stateSince: 1000, now: 1000 + 31 * 60))
    }

    @Test("decode 永不暗（哪怕很久）")
    func decodeNever() {
        #expect(!DisplayPolicy.dimmed(state: .decode, stateSince: 0, now: 3600 * 10))
    }

    @Test("其他状态永不暗")
    func othersNever() {
        for s in [PanelState.done, .prefill, .starting, .unavailable] {
            #expect(!DisplayPolicy.dimmed(state: s, stateSince: 0, now: 3600 * 10))
        }
    }
}
