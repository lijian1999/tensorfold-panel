# TensorFold 副屏性能仪表盘（TFPanel）

## 这是什么

让拓展坞上那块 3.5 英寸小副屏实时显示本地模型的运行状态：解码速度、预填充速度和进度、并发的流数、今日用量和按 API 价格折算的费用。

模型（Qwen3.8 Flash Next）用 TensorFold 跑在 DGX Spark 上，副屏接在 Spark 的 C 口。客户端照常连 Spark 的 8888 端口，什么都不用改。

## 现在的状态

第 2 版（DGX Spark）的设计和原型已于 2026-10-04 确认，**程序还没有实现**。

第 1 版（Mac Studio 上的同进程采集器 + SwiftUI 显示程序）已从仓库删除，需要时看 git 提交 `6c9ad9a`。

## 文档

- 设计文档：[`docs/design.md`](docs/design.md)
- 可交互原型：[`docs/dashboard-prototype.html`](docs/dashboard-prototype.html)。浏览器直接打开；地址后加 `?kiosk=1` 只显示屏幕本身，再加 `&demo=<名字>` 停在某个画面。
- 原型在副屏上的实拍截图：[`docs/prototype-shots/`](docs/prototype-shots/)
- 给执行者的工作约定：[`AGENTS.md`](AGENTS.md)

## 目录

| 目录 | 内容 | 状态 |
| --- | --- | --- |
| `docs/` | 设计文档、原型、截图、验证外挂用的草稿 | 已有 |
| `scripts/dev/` | 在副屏上看原型、截副屏的小工具 | 已有 |
| `panel/` | 副屏程序 | 待实现 |
| `hook/` | 容器内外挂 | 待实现 |
| `fixtures/` | 各状态的指标快照样例 | 待实现 |

安装、日常使用和卸载的说明等程序实现后再补。
