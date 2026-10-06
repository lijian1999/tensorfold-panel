# TensorFold 副屏性能仪表盘（TFPanel）

## 这是什么

让拓展坞上那块 3.5 英寸小副屏（960×640）实时显示这台 DGX Spark 上模型的运行状态：解码速度、预填充速度和进度、同时在跑的流数、今日用量，以及按 API 价格折算出来的费用。

模型（Qwen3.8 Flash Next）用 TensorFold 或 vLLM 跑在 Spark 上，副屏接在 Spark 的 C 口。副屏程序自己认出当前跑的是哪种引擎、在哪个端口，换引擎不用改配置、也不用重启副屏程序。客户端照常连模型那边的端口，什么都不用改。

## 组成

| 部件 | 在哪 | 做什么 |
| --- | --- | --- |
| 外挂 | Docker 容器里，TensorFold 进程内 | 给 `/health` 的返回加一段 `tfpanel`：每条流的阶段、提示长度、缓存命中、预填充进度、已输出 token 数。只读不写，读不到就整段不输出，不影响推理。只对 TensorFold 有效，vLLM 不需要外挂 |
| 副屏程序 | Spark 主机，`~/tfpanel/` | 一个 Python 进程：按引擎读指标——TensorFold 读 `/health` 和 `/metrics`，vLLM 只读 `/metrics`；两种引擎都读 `/proc/meminfo`。算出状态、合计速度、一轮统计、今日用量和费用，再画到副屏上 |
| 今日用量文件 | Spark 主机，`~/.local/state/tfpanel/` | `usage.json` 记当天的账（含上一次读到的累计值），`usage-history.jsonl` 每天追加一笔。副屏程序没在跑的那段时间，重启后按这里的基数把用量补上 |

## 两种引擎的差别

两种引擎的解码画面、完成画面长得一样，区别都在数字的来源准不准、来得快不快。

| 方面 | TensorFold | vLLM |
| --- | --- | --- |
| 解码速度和完成画面 | 准数 | 准数 |
| 今日用量和费用 | 准数 | 准数 |
| 流指示点（解码、预填充、排队） | 准数 | 准数；并发时有流中途断开会短暂数错，回到空闲时自动校正 |
| 预填充开始时的提示长度、缓存命中 | 准数，立刻有 | 准数，但晚 0.2–5 秒（等引擎算完第一步） |
| 预填充速度和进度 | 引擎实报，约 0.9 秒更新一次 | 按最近的平均速度估算 |
| 看到新请求的延迟 | 0.1 秒内 | 短请求约 0.2 秒；长提示从头算 2–5 秒，期间副屏还停在上一个画面 |
| 中途断开的请求 | — | 不出完成画面，不计入请求数，已用的 token 计入今日用量 |

vLLM 这边每次读取都会在 vLLM 的容器日志里留一行访问记录，空闲时每秒 4 行、忙时每秒 10 行，日志会长期增长。建议在 vLLM 的启动参数里加上 `--disable-access-log-for-endpoints /health,/metrics,/v1/models`。

## 安装

从零装一遍是下面四步。装过之后再更新见"更新和卸载"。

### 第一步：把程序拷到 Spark

在 MacBook Pro 上，仓库根目录执行。把 `panel/`、`fixtures/`、`scripts/`、`hook/` 四个目录同步到 Spark 的 `~/tfpanel/`：

```sh
scripts/sync.sh
```

### 第二步：启动副屏程序

在 Spark 上执行（`ssh spark` 之后）。副屏上应该马上出现画面；找不到副屏时程序会等待并往日志里写一行。

```sh
~/tfpanel/scripts/tfpanel.sh start
```

### 第三步：装开机启动项

在 Spark 上执行，把启动项写进 `~/.config/autostart/`：

```sh
~/tfpanel/scripts/install-autostart.sh
```

它只写启动项文件，不改系统设置，但需要你重启一次桌面会话才认这个文件（登出再登入，或者直接重启机器）。装完它还会检查有没有开启自动登录，没有的话提示一条 `sudo sed -i ...` 命令：把这条命令也复制执行一次（要输管理员密码），否则每次重启机器都得手动 `tfpanel.sh start` 一次。

### 第四步：装外挂

这一步只在用 TensorFold 时需要，跑的是 vLLM 就直接跳过。可选。不装副屏也能工作，只是预填充画面降级：圆圈里只显示已经等了多久，没有预填充速度和进度条。

先在 MacBook Pro 上把补丁拷到 Spark 的部署仓库里：

```sh
scripts/hook.sh install
```

再在 Spark 上进入部署仓库重启模型，补丁是在构建镜像时打上去的，不重启不生效：

```sh
PULL=0 ./start.sh restart
```

`PULL=0` 是强制在本地重新构建镜像（改了 `patches/` 必须重建镜像才带得上补丁）。重启期间模型不可用，大约几分钟。装完在 MacBook Pro 上查一下外挂有没有生效，第二行打印"外挂已生效"才算装上：

```sh
scripts/hook.sh status
```

## 日常使用

四个命令都在 Spark 上执行。没在跑就启动，已经在跑就提示一句、不会开第二个：

```sh
~/tfpanel/scripts/tfpanel.sh start
```

停掉：

```sh
~/tfpanel/scripts/tfpanel.sh stop
```

先停再起（改完配置用它）：

```sh
~/tfpanel/scripts/tfpanel.sh restart
```

在运行就打印进程号、已运行时间、CPU 和内存占用：

```sh
~/tfpanel/scripts/tfpanel.sh status
```

日志在 Spark 的 `~/.local/state/tfpanel/tfpanel.log`，超过 1 MB 时下一次 start 会先清空它。

需要操作 Spark 桌面时先 `stop`：副屏通常是 Spark 唯一的屏幕，全屏的仪表盘会盖住桌面（窗口不吃点击、也不抢键盘焦点，但鼠标和顶栏都会被挡住）。

## 配置

配置文件在 Spark 的 `~/.config/tfpanel/config.json`，没有这个文件就全用默认值。只写想改的键即可，值类型和默认值对不上的键会被整键忽略。

| 键名 | 含义 | 默认值 |
| --- | --- | --- |
| `base_url` | 只用这一个接口地址（写了它就不再自动找） | 空 |
| `base_urls` | 接口地址列表，按顺序试，用第一个认得出引擎的 | `["http://127.0.0.1:8888", "http://127.0.0.1:8000"]` |
| `monitor_match` | 找副屏按什么匹配：`manufacturer` 按厂商名，`connector` 按接口名 | `manufacturer` |
| `monitor_value` | 上面那种匹配要等于什么 | `DRS` |
| `round_gap_s` | 一轮间隔：多久没有新请求算这一轮结束 | `60.0` |
| `prefill_short_s` | 短预填充阈值：前这么多秒不换画面 | `3.0` |
| `done_hold_s` | 完成画面停留多久 | `4.0` |
| `dim_after_s` | 空闲多久后把画面调暗 | `1800.0` |
| `anim_fps` | 解码、预填充期间画面每秒重画几次（1–30）。画面和推理共用显卡，30 时解码会慢约 5%，10 时慢约 2% | `10.0` |
| `timezone` | 时区，"今日"按它算 | `America/Los_Angeles` |
| `price_input` | 输入单价（每百万 token，不含缓存命中） | `0.15` |
| `price_cached` | 缓存命中单价（每百万 token） | `0.016` |
| `price_output` | 输出单价（每百万 token） | `0.47` |
| `currency` | 货币符号 | `$` |
| `state_dir` | 存今日用量文件的目录（`usage.json`、`usage-history.jsonl`） | `~/.local/state/tfpanel` |
| `model_name` | 从接口读不到模型名时显示的名字 | `Qwen3.8-Flash-Next` |

比如把一轮间隔改成 30 秒、输出单价改成 0.20、时区改成东八区：

```json
{
  "round_gap_s": 30,
  "price_output": 0.20,
  "timezone": "Asia/Shanghai"
}
```

改完重启副屏程序才生效（在 Spark 上执行）：

```sh
~/tfpanel/scripts/tfpanel.sh restart
```

## 画面说明

圆圈（270° 圆弧）里显示主数字，右边约 1/3 是三栏数据。下面是单个请求时五个状态各显示什么；并发时右侧三栏会换成"本轮请求 / 累计输出 / 本轮平均"。

| 状态 | 圆圈里 | 右侧三栏 |
| --- | --- | --- |
| 引擎离线 | "引擎离线 / 等待引擎响应…"，底环变暗 | 今日费用 / 已离线 / 内存。状态条右边写"上次模型"和最后一次连上的引擎名，例如 `上次模型 Qwen3.8-Flash-Next · vLLM` |
| 空闲（今日统计） | "今日费用 · 美元"，主数字是今天累计费用（`$0.60` 这样），下面一行写日期和时区 | 今日输入（下方"缓存命中 66%"）/ 今日输出 / 今日请求（下方"上次 63.6 tok/s"）。状态条上模型名后面标出引擎，例如 `Qwen3.8-Flash-Next · vLLM` |
| 预填充中 | 前 3 秒保持上一个画面，只在状态条写"已用时 x.x s"；超过 3 秒（或者预计要 3 秒以上、缓存未命中）才换成预填充画面："预填充速度 · tok/s"，琥珀色圆弧，下面是进度条和"已算 10.2K / 24.6K" | 缓存命中 x%（下方"命中 / 提示"）/ 已等待 x.x s（下方"剩余约 x s"）/ 内存 |
| 预填充中（vLLM） | 布局同上，标题旁边多一个琥珀色描边的"近期平均"标记；主数字是最近几次请求的平均预填充速度，这次预填充期间不变；进度条按时间匀速前进，写"已算约 10.2K / 24.6K" | 同上 |
| 解码中 | "解码速度 · tok/s"，薄荷绿圆弧，下面是上下文占用条（80% 以下灰、80%–95% 琥珀、95% 以上红） | 输出 / 平均 / 峰值 |
| 完成（停 4 秒） | "平均速度 · tok/s"，引擎给的精确值，带"精确"标记 | 输出（下方"提示 x tok"）/ 缓存命中 / 接受率 |

状态条最左边是流指示点：TensorFold 的个数等于并发上限（现在 5 个）；vLLM 从 4 个起，同时在跑的流多了再加，最多画 12 个。绿色是在解码的流，琥珀色是在预填充的流，灰色是空着的；有排队请求时后面追加"+2"这样一段。间隔不超过 `round_gap_s`（默认 60 秒）的新请求，或者上一个还没跑完就来的新请求，都算同一"一轮"；一轮里请求数 ≥ 2（包括同时在跑的），右侧三栏就固定成本轮统计，本轮结束才切回今日统计。"外挂未生效"出现在状态条里"内存"前面，是琥珀色的，只有引擎是 TensorFold 时才可能出现——vLLM 不需要外挂，所以不会出现这四个字；这时状态条左边只写模型名、不写引擎名。它的意思是容器里那段外挂没装上或者失效了：副屏照常工作，只是看不到预填充速度和进度。这时先在 MacBook Pro 上跑 `scripts/hook.sh status` 看补丁在不在、`/health` 里有没有 `tfpanel`，然后重新 `scripts/hook.sh install`，再在 Spark 上重启模型。

## 更新和卸载

更新：先在 MacBook Pro 上同步，再在 Spark 上重启副屏程序。用 TensorFold 时，改过 `hook/` 里的东西（或者升级了 TensorFold 版本）还要重新 `scripts/hook.sh install` 并重启模型，和安装第四步一样；用 vLLM 时不用管外挂，同步加重启就够了。

```sh
scripts/sync.sh
```

```sh
~/tfpanel/scripts/tfpanel.sh restart
```

卸载按顺序做：先在 Spark 上停掉程序，再删掉开机启动项：

```sh
~/tfpanel/scripts/tfpanel.sh stop
```

```sh
~/tfpanel/scripts/install-autostart.sh --remove
```

然后在 MacBook Pro 上把补丁从部署仓库里删掉（用 TensorFold 时才做这一步，vLLM 没有装过外挂）：

```sh
scripts/hook.sh remove
```

删完还要在 Spark 上重启一次模型（`PULL=0 ./start.sh restart`）才算把外挂从运行中的模型上摘掉。最后在 Spark 上删掉这两个目录：

```sh
rm -rf ~/tfpanel ~/.local/state/tfpanel
```

## 开发

代码在 MacBook Pro 上写，程序在 Spark 上跑。测试只用标准库 `unittest`。在 MacBook Pro 上，仓库根目录跑这两条：

```sh
python3 -m unittest discover -s panel/tests -t .
```

```sh
python3 -m unittest discover -s hook/tests -t hook
```

第一条里绘制那一套（`panel/tests/test_render.py`）在没有 cairo / Pango 的机器上会整个文件跳过，只能在 Spark 上跑；同步过去之后在 Spark 上执行：

```sh
cd ~/tfpanel && python3 -m unittest discover -s panel/tests -t .
```

离屏截图：把 `fixtures/` 里的快照样例逐个画成 960×640 的 PNG，画到内存图片上，不需要显示器。在 Spark 上执行，默认写到 `/tmp/tfpanel-shots/`，`--out 目录` 可以换地方，后面可以跟样例名只截一两张：

```sh
cd ~/tfpanel && python3 scripts/offscreen.py
```

| 目录 | 内容 |
| --- | --- |
| `docs/` | 设计文档、可交互原型、原型在副屏上的实拍截图、给执行者的任务说明 |
| `panel/` | 副屏程序：读取、引擎适配、采集、今日用量、视图模型、绘制、窗口 |
| `hook/` | 容器内外挂的两个文件、自检脚本、生成补丁的脚本 |
| `fixtures/` | 各状态的指标快照样例，测试和离屏截图都用它们。`fixtures/vllm/` 是在真实 vLLM 上录下来的 `/metrics` 序列，适配器的测试用它们 |
| `scripts/` | 同步到 Spark、装开机启动项、管理副屏程序、离屏截图；`scripts/dev/` 是在副屏上看原型和截副屏的小工具 |

想看实现细节：设计文档 [`docs/design.md`](docs/design.md) 和支持 vLLM 的增补设计 [`docs/design-vllm.md`](docs/design-vllm.md)，可交互原型 [`docs/dashboard-prototype.html`](docs/dashboard-prototype.html)（浏览器直接打开，地址后加 `?kiosk=1` 只显示屏幕本身，再加 `&demo=<名字>` 停在某个画面），原型在副屏上的实拍截图在 [`docs/prototype-shots/`](docs/prototype-shots/)，给执行者的工作约定是 [`AGENTS.md`](AGENTS.md)。
