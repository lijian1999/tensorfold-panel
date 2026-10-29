// 翻译自 panel/tests/test_fixtures.py：检查 fixtures/*.json 里各状态的指标快照样例格式。
import Foundation
import Testing
@testable import PanelCore

// 基础快照的顶层 15 个键。
private let TOP_KEYS: Set<String> = [
    "version", "state", "hook", "engine", "model", "context_max",
    "lanes", "decode", "prefill", "context_used", "last", "round", "today",
    "memory", "offline_s",
]

private let DECODER_OBJ_KEYS: Set<String> = ["tps", "tps_peak", "tps_avg", "output_tokens", "ttft_s"]
private let PREFILL_OBJ_KEYS: Set<String> = [
    "elapsed_s", "prompt_tokens", "cached_tokens", "filled_tokens",
    "tps", "remaining_s", "est_s", "cache_miss", "estimated",
]
private let ROUND_OBJ_KEYS: Set<String> = [
    "requests", "running", "output_tokens", "decode_tps_avg", "exact",
    "elapsed_s", "active",
]
private let LAST_OBJ_KEYS: Set<String> = [
    "prompt_tokens", "cached_tokens", "completion_tokens", "decode_tps",
    "prefill_tps", "ttft_s", "acceptance_rate", "context_used",
]
private let TODAY_OBJ_KEYS: Set<String> = [
    "date", "prompt_tokens", "cached_tokens", "completion_tokens",
    "requests", "cost",
]
private let MEMORY_OBJ_KEYS: Set<String> = ["used_gb", "total_gb"]

private let STATES: Set<String> = ["offline", "idle", "prefill", "decode", "done"]
private let HOOKS: Set<String> = ["ok", "missing"]

// 外挂失效时这些字段必须为 null。
private let PREFILL_HOOK_NULL_KEYS: Set<String> = ["cached_tokens", "filled_tokens", "tps",
                                                   "remaining_s", "est_s"]

// 应有的 17 个样例文件名。
private let FIXTURE_NAMES: Set<String> = [
    "prefill-est.json",
    "idle-vllm.json",
    "offline-vllm.json",
    "offline.json",
    "idle.json",
    "idle-nohook.json",
    "prefill.json",
    "prefill-fresh.json",
    "prefill-miss.json",
    "prefill-nohook.json",
    "prefill-short.json",
    "decode.json",
    "decode-multi.json",
    "decode-ctx-warn.json",
    "queue.json",
    "done.json",
    "round-rest.json",
]

/// fixtures/ 下全部 *.json，按文件名排序（不进子目录）。
private func fixturePaths() -> [URL] {
    let items = (try? FileManager.default.contentsOfDirectory(at: fixturesDir,
                                                             includingPropertiesForKeys: nil)) ?? []
    return items.filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// 读一个样例文件。
private func load(_ path: URL) -> JSON {
    let data = try! Data(contentsOf: path)
    return JSON.parse(data)!
}

/// 对象的键集合（不是对象时为空集，断言会因此失败）。
private func objKeys(_ value: JSON?) -> Set<String> {
    guard let o = value?.object else { return [] }
    return Set(o.keys)
}

/// 逐个快照样例执行回调，失败时报出文件名。（对应 each_fixture；循环翻成普通循环，文件名写进断言说明）
private func eachFixture() -> [URL] {
    let paths = fixturePaths()
    #expect(!paths.isEmpty, "fixtures/ 下没有找到任何 JSON 样例: \(fixturesDir.path)")
    return paths
}

@Suite struct TestFixtureFiles {
    @Test func test_fixture_files_exist() {
        // fixtures/ 里恰好有 17 个样例文件，不多不少。
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: fixturesDir.path, isDirectory: &isDir) && isDir.boolValue,
                "缺少目录 \(fixturesDir.path)")
        var found: Set<String> = []
        for path in fixturePaths() { found.insert(path.lastPathComponent) }
        #expect(found == FIXTURE_NAMES)
    }
}

@Suite struct TestFixtureFormat {
    @Test func test_loadable_and_object() {
        // 每个样例都能读出来，而且顶层是对象。
        for path in eachFixture() {
            let snap = load(path)
            #expect(snap.object != nil, "\(path.lastPathComponent)")
        }
    }

    @Test func test_top_level_keys() {
        // 顶层键恰好是基础快照的 15 个键。
        for path in eachFixture() {
            let snap = load(path)
            #expect(objKeys(snap) == TOP_KEYS, "\(path.lastPathComponent)")
        }
    }

    @Test func test_version_state_hook() {
        // version 为 2；state、hook 的取值合法。
        for path in eachFixture() {
            let snap = load(path)
            let name = path.lastPathComponent
            #expect(snap["version"] == .int(2), "\(name)")
            #expect(STATES.contains(snap["state"]?.string ?? ""), "\(name)")
            #expect(HOOKS.contains(snap["hook"]?.string ?? ""), "\(name)")
        }
    }

    @Test func test_engine() {
        // engine 只能是 tensorfold 或 vllm。
        let engines: Set<String> = ["tensorfold", "vllm"]
        for path in eachFixture() {
            #expect(engines.contains(load(path)["engine"]?.string ?? ""), "\(path.lastPathComponent)")
        }
    }

    @Test func test_estimated() {
        // 有预填充时 estimated 是布尔；TensorFold 的样例必须是 False。
        for path in eachFixture() {
            let snap = load(path)
            let name = path.lastPathComponent
            if let prefill = snap["prefill"], !prefill.isNull {
                #expect(prefill["estimated"]?.bool != nil, "\(name)")
                if snap["engine"]?.string == "tensorfold" {
                    #expect(prefill["estimated"]?.bool == false, "\(name)")
                }
            }
        }
    }

    @Test func test_lanes() {
        // lanes 恰好 4 个整数键。
        for path in eachFixture() {
            let lanes = load(path)["lanes"] ?? [:]
            let name = path.lastPathComponent
            #expect(objKeys(lanes) == ["max", "decoding", "prefilling", "waiting"], "\(name)")
            for (_, value) in lanes.object ?? [:] {
                #expect(value.int != nil, "\(name)")
            }
        }
    }

    @Test func test_optional_object_keys() {
        // decode、prefill、round、last 要么是 null，要么键恰好齐全。
        let checks: [(String, Set<String>)] = [
            ("decode", DECODER_OBJ_KEYS),
            ("prefill", PREFILL_OBJ_KEYS),
            ("round", ROUND_OBJ_KEYS),
            ("last", LAST_OBJ_KEYS),
        ]
        for path in eachFixture() {
            let snap = load(path)
            let name = path.lastPathComponent
            for (field, keys) in checks {
                let obj = snap[field]
                if let obj, !obj.isNull {
                    #expect(objKeys(obj) == keys, "\(name) \(field)")
                }
            }
        }
    }

    @Test func test_state_consistency() {
        // 状态与并发数、offline_s 的互相约束。
        for path in eachFixture() {
            let snap = load(path)
            let name = path.lastPathComponent
            if snap["state"]?.string == "decode" {
                #expect(!(snap["decode"]?.isNull ?? true), "\(name) decode")
                #expect((snap["lanes"]?["decoding"]?.number ?? -1) >= 1, "\(name) decode")
            }
            if (snap["lanes"]?["prefilling"]?.number ?? 0) >= 1 {
                #expect(!(snap["prefill"]?.isNull ?? true), "\(name) prefill")
            }
            if snap["state"]?.string == "offline" {
                #expect(snap["offline_s"]?.number != nil, "\(name) offline_s")
            } else {
                #expect(snap["offline_s"].isNone, "\(name) offline_s")
            }
        }
    }

    @Test func test_missing_hook_nulls() {
        // 外挂失效且有预填充时，prefill 里依赖外挂的字段都是 null。
        for path in eachFixture() {
            let snap = load(path)
            let name = path.lastPathComponent
            if snap["hook"]?.string == "missing", let prefill = snap["prefill"], !prefill.isNull {
                for key in PREFILL_HOOK_NULL_KEYS {
                    #expect(prefill[key].isNone, "\(name) \(key)")
                }
            }
        }
    }

    @Test func test_today_and_memory_keys() {
        // today、memory 的键齐全。
        for path in eachFixture() {
            let snap = load(path)
            let name = path.lastPathComponent
            #expect(objKeys(snap["today"]) == TODAY_OBJ_KEYS, "\(name) today")
            #expect(objKeys(snap["memory"]) == MEMORY_OBJ_KEYS, "\(name) memory")
        }
    }
}
