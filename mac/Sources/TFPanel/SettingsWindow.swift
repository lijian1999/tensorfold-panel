// 设置窗口（接口约定 9.5）：三页「引擎 / 费用 / 副屏」，内容是 SwiftUI。
// 表的数据、各输入框的文字放在 SettingsModel 里，SwiftUI 视图只读写它。
import AppKit
import PanelCore
import SwiftUI

enum SettingsPage: String, CaseIterable { case engine, price, screen }

/// 费用表一行的编辑状态（单价表的行 + 六个输入框 + 别名框 + 是否填错）。
struct PriceRowVM: Identifiable, Equatable {
    let model: String
    var present: Bool
    var official: Bool             // 没填用户价，正在按内置 DeepSeek 官方价目算
    var tiered: Bool              // 分时计价：高峰三项也参与
    var input: String             // 空闲/平坦的未命中输入
    var cached: String            // 空闲/平坦的缓存命中输入
    var output: String            // 空闲/平坦的输出
    var peakInput: String
    var peakCached: String
    var peakOutput: String
    var aliases: String
    var dirty: Bool                // 这一行被改过、还没写进设置
    var invalid: Bool

    var id: String { model }
}

@MainActor
final class SettingsModel: ObservableObject {
    private let controller: AppController

    // 引擎页
    @Published var engineChoice = "omlx"      // omlx / tensorfold，跟设置里的 engine 对应
    @Published var addressText = ""
    @Published var keyMode: KeyMode = .auto
    @Published var manualKeyText = ""
    @Published var statusNote = "未连接"       // controller.issue.message ?? "已连接"
    // 费用页
    @Published var rows: [PriceRowVM] = []
    @Published var currencyText = "$"          // 当前货币符号：$ / ¥
    // 副屏页
    @Published var screenNameText = ""
    // 当前页
    @Published var page: SettingsPage = .engine

    init(controller: AppController) {
        self.controller = controller
        let s = controller.settings
        engineChoice = s.engine == "tensorfold" ? "tensorfold" : "omlx"
        addressText = s.address
        keyMode = s.keyMode
        manualKeyText = s.manualKey
        screenNameText = s.screenName
        statusNote = controller.issue.message ?? "已连接"
        currencyText = s.currency
        rebuildRows(keeping: [])
    }

    /// 打开窗口时从设置重新取各输入框的文字（保留还没提交的行编辑）。
    func reload() {
        let s = controller.settings
        engineChoice = s.engine == "tensorfold" ? "tensorfold" : "omlx"
        addressText = s.address
        keyMode = s.keyMode
        manualKeyText = s.manualKey
        screenNameText = s.screenName
        currencyText = s.currency
        statusNote = controller.issue.message ?? "已连接"
        rebuildRows(keeping: rows)
    }

    /// 状态变了（由 StatusMenu 的 onStatusChange 转过来）：刷新状态行和模型列表。
    func statusChanged(issue: EngineIssue, modelIDs: [String]) {
        statusNote = issue.message ?? "已连接"
        rebuildRows(keeping: rows)
    }

    /// 按当前模型列表 + knownModels + 已填单价重排行；
    /// keeping 里同名行没改过就按设置重建（official 行会跟着货币刷新），改过的原样保留。
    private func rebuildRows(keeping: [PriceRowVM], refreshOfficial: Bool = false) {
        var edits: [String: PriceRowVM] = [:]
        for r in keeping { edits[r.model] = r }
        rows = priceRows(current: controller.modelIDs,
                         known: controller.settings.knownModels,
                         prices: controller.settings.prices).map { row in
            if var e = edits[row.model], e.dirty || (!refreshOfficial && !e.official) {
                e.present = row.present
                return e
            }
            let match = priceForUse(model: row.model,
                                     prices: controller.settings.prices,
                                     currency: controller.settings.currency)
            func text(_ value: Double?) -> String {
                guard let v = value else { return "" }
                return priceText(v)
            }
            func field(_ keyPath: KeyPath<ModelPrice, Double?>) -> String {
                text(match?.price[keyPath: keyPath])
            }
            let p = match?.price
            return PriceRowVM(model: row.model, present: row.present,
                              official: match?.official ?? false,
                              tiered: p?.hasPeak ?? false,
                              input: text(p?.input), cached: text(p?.cached), output: text(p?.output),
                              peakInput: field(\.peakInput), peakCached: field(\.peakCached),
                              peakOutput: field(\.peakOutput),
                              aliases: (p?.aliases ?? []).joined(separator: ", "),
                              dirty: false, invalid: false)
        }
    }

    /// 行里某个文字框的绑定（改动先只留在界面上，按回车或关窗时生效）。
    func text(_ model: String, _ keyPath: WritableKeyPath<PriceRowVM, String>) -> Binding<String> {
        Binding(
            get: { self.rows.first { $0.model == model }?[keyPath: keyPath] ?? "" },
            set: { v in
                guard let i = self.rows.firstIndex(where: { $0.model == model }) else { return }
                self.rows[i][keyPath: keyPath] = v
                self.rows[i].invalid = false
                self.rows[i].dirty = true
            }
        )
    }

    /// “分时”开关的绑定：改动先只留在界面上，按回车或关窗时生效。
    func tiered(_ model: String) -> Binding<Bool> {
        Binding(
            get: { self.rows.first { $0.model == model }?.tiered ?? false },
            set: { v in
                guard let i = self.rows.firstIndex(where: { $0.model == model }) else { return }
                self.rows[i].tiered = v
                self.rows[i].invalid = false
                self.rows[i].dirty = true
            }
        )
    }

    // MARK: - 马上生效的（分段控件、下拉框、删除按钮）

    /// 换引擎：写进设置（engine 的 setter 会把默认地址跟着换），立刻生效。
    func applyEngine(_ name: String) {
        engineChoice = name
        controller.settings.engine = name
        addressText = controller.settings.address   // setter 可能换了默认地址，同步显示
        controller.settingsChanged()
    }

    func applyKeyMode(_ mode: KeyMode) {
        keyMode = mode
        controller.settings.keyMode = mode
        controller.settingsChanged()
    }

    /// 换货币：只换符号和文字，数字不按汇率换算；官方价目自动换成所选货币的那一组。
    /// 没改过的行按新货币重建，改过但还没提交的行原样保留。
    func applyCurrency(_ symbol: String) {
        currencyText = symbol
        controller.settings.currency = symbol
        rebuildRows(keeping: rows, refreshOfficial: true)
        controller.settingsChanged()
    }

    /// 费用页的说明文字，跟着货币走
    var currencyNote: String {
        currencyName(currencyText)
            + " / 百万 token。DeepSeek Flash 没填用户价时按官方峰谷价目；其它模型自己查了 API 价格填，没填的不算进今日费用"
    }

    /// 峰谷与别名的说明
    var peakNote: String {
        "分时：高峰按北京时间周一至周五 9:00–12:00、14:00–18:00；周末和中国法定节假日全天空闲。"
            + "旧模型名写在“别名”里，共用这一组价"
    }

    func forget(_ model: String) {
        controller.settings.forgetModel(model)
        rebuildRows(keeping: rows.filter { $0.model != model })
        controller.settingsChanged()
    }

    // MARK: - 输入框生效（按回车、关窗时）

    /// 一行按 parseEditedPrice 的结果生效：valid 写入；empty 删掉用户价（官方价仍适用）；
    /// invalid 不写、标红。生效后按设置重画这一行，免得界面上仍挂着没保存的值。
    func commitRow(_ model: String) {
        guard let i = rows.firstIndex(where: { $0.model == model }) else { return }
        let r = rows[i]
        switch parseEditedPrice(input: r.input, cached: r.cached, output: r.output,
                                 peakInput: r.peakInput, peakCached: r.peakCached,
                                 peakOutput: r.peakOutput, tiered: r.tiered,
                                 aliases: r.aliases) {
        case .valid(let p):
            controller.settings.prices[model] = p
            rebuildRows(keeping: rows.filter { $0.model != model })
        case .empty:
            controller.settings.prices.removeValue(forKey: model)
            rebuildRows(keeping: rows.filter { $0.model != model })
        case .invalid:
            rows[i].invalid = true
        }
        controller.settingsChanged()
    }

    func commitAddress() {
        let t = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { controller.settings.address = t }  // 去掉空白后为空就不写
        controller.settingsChanged()
    }

    func commitManualKey() {
        controller.settings.manualKey = manualKeyText
        controller.settingsChanged()
    }

    func commitScreenName() {
        let t = screenNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { controller.settings.screenName = t }  // 去掉空白后为空就不写
        controller.settingsChanged()
    }

    /// 关窗时把改动过的行写进设置，settingsChanged() 调一次。
    /// 没改过的行不写：否则官方价目会被当成用户价存下来，换货币时就不跟着换了。
    func commitAll() {
        let s = controller.settings
        let addr = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !addr.isEmpty { s.address = addr }
        s.manualKey = manualKeyText
        let name = screenNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { s.screenName = name }
        var prices = s.prices
        for (i, r) in rows.enumerated() where r.dirty {
            switch parseEditedPrice(input: r.input, cached: r.cached, output: r.output,
                                     peakInput: r.peakInput, peakCached: r.peakCached,
                                     peakOutput: r.peakOutput, tiered: r.tiered,
                                     aliases: r.aliases) {
            case .valid(let p):
                prices[r.model] = p
                rows[i].invalid = false
            case .empty:
                prices.removeValue(forKey: r.model)
                rows[i].invalid = false
            case .invalid:
                rows[i].invalid = true
            }
        }
        s.prices = prices
        controller.settingsChanged()
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let controller: AppController
    private let model: SettingsModel
    private var window: NSWindow?

    init(controller: AppController) {
        self.controller = controller
        self.model = SettingsModel(controller: controller)
        super.init()
    }

    /// 切到那一页并带到前台；关掉后再打开复用同一个窗口。
    func show(page: SettingsPage) {
        model.page = page
        model.reload()
        let win: NSWindow
        if let existing = window {
            win = existing
        } else {
            win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                           styleMask: [.titled, .closable],   // 可关闭，不可缩放
                           backing: .buffered, defer: false)
            win.title = "设置"
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.contentViewController = NSHostingController(rootView: SettingsRootView(model: model))
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// 关闭窗口时把改动过的行和各输入框写进设置。
    func windowWillClose(_ notification: Notification) {
        model.commitAll()
    }

    /// 由 StatusMenu 的 onStatusChange 转发。
    func statusChanged() {
        model.statusChanged(issue: controller.issue, modelIDs: controller.modelIDs)
    }
}

// MARK: - SwiftUI 界面（照原型的 mac-win）

private struct SettingsRootView: SwiftUI.View {
    @ObservedObject var model: SettingsModel

    var body: some SwiftUI.View {
        TabView(selection: $model.page) {
            enginePage
                .tabItem { Text("引擎") }
                .tag(SettingsPage.engine)
            pricePage
                .tabItem { Text("费用") }
                .tag(SettingsPage.price)
            screenPage
                .tabItem { Text("副屏") }
                .tag(SettingsPage.screen)
        }
        .frame(width: 640, height: 500)
    }

    private var enginePage: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 8) {
            formRow("引擎") {
                Picker("", selection: $model.engineChoice) {
                    Text("oMLX").tag("omlx")
                    Text("TensorFold").tag("tensorfold")
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: model.engineChoice) { _, name in
                    model.applyEngine(name)
                }
            }
            note("换引擎会自动换成那个引擎的默认地址；手改过的地址不动")
            formRow("接口地址") {
                TextField("", text: $model.addressText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.commitAddress() }
            }
            formRow("API key") {
                Picker("", selection: $model.keyMode) {
                    Text("自动").tag(KeyMode.auto)
                    Text("手填").tag(KeyMode.manual)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: model.keyMode) { _, newMode in
                    model.applyKeyMode(newMode)
                }
            }
            if model.keyMode == .auto {
                note(model.engineChoice == "tensorfold"
                     ? "TensorFold 默认不设 API key，自动模式不读任何文件"
                     : "读 ~/.omlx/settings.json 里的 auth.api_key")
            } else {
                formRow(" ") {
                    SecureField("", text: $model.manualKeyText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.commitManualKey() }
                }
            }
            Spacer(minLength: 8)
            note(model.statusNote)
        }
        .padding(12)
    }

    private var pricePage: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 8) {
            formRow("货币") {
                Picker("", selection: $model.currencyText) {
                    Text("美元").tag("$")
                    Text("人民币").tag("¥")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: model.currencyText) { _, symbol in
                    model.applyCurrency(symbol)
                }
            }
            note(model.currencyNote)
            note(model.peakNote)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.rows) { row in
                        priceCard(row)
                        Divider()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 一个模型的价目块：模型名 / 官方价目标记 / 分时开关 / 别名 / 六个价框。
    @ViewBuilder
    private func priceCard(_ row: PriceRowVM) -> some SwiftUI.View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(row.model)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(row.present ? .primary : .secondary)
                    .frame(maxWidth: 300, alignment: .leading)
                if row.official {
                    Text("官方价目")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
                Toggle("分时", isOn: self.model.tiered(row.model))
                    .toggleStyle(.switch)
                    .font(.callout)
                if !row.present {
                    Button("删除") { self.model.forget(row.model) }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
            }
            HStack(spacing: 6) {
                Text("别名").font(.callout).foregroundColor(.secondary)
                    .frame(width: 44, alignment: .leading)
                TextField("旧模型名，用逗号分隔", text: self.model.text(row.model, \.aliases))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 460)
                    .onSubmit { self.model.commitRow(row.model) }
            }
            HStack(spacing: 6) {
                Text(" ").frame(width: 44)
                Text("输入").font(.callout).foregroundColor(.secondary).frame(width: 76, alignment: .leading)
                Text("缓存命中").font(.callout).foregroundColor(.secondary).frame(width: 76, alignment: .leading)
                Text("输出").font(.callout).foregroundColor(.secondary).frame(width: 76, alignment: .leading)
            }
            if row.tiered {
                priceLine(row, label: "高峰", input: \.peakInput, cached: \.peakCached, output: \.peakOutput)
                priceLine(row, label: "空闲", input: \.input, cached: \.cached, output: \.output)
            } else {
                priceLine(row, label: "单价", input: \.input, cached: \.cached, output: \.output)
            }
            if row.invalid {
                Text(row.tiered ? "分时的六个格子都要填，填不小于 0 的数" : "三项都要填，填不小于 0 的数")
                    .font(.callout)
                    .foregroundColor(.red)
                    .padding(.leading, 50)
            }
        }
    }

    private func priceLine(_ row: PriceRowVM, label: String,
                           input: WritableKeyPath<PriceRowVM, String>,
                           cached: WritableKeyPath<PriceRowVM, String>,
                           output: WritableKeyPath<PriceRowVM, String>) -> some SwiftUI.View {
        HStack(spacing: 6) {
            Text(label).font(.callout).foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)
            priceField(row.model, input)
            priceField(row.model, cached)
            priceField(row.model, output)
        }
    }

    private var screenPage: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 8) {
            formRow("屏幕名") {
                TextField("", text: $model.screenNameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.commitScreenName() }
            }
            Spacer(minLength: 8)
        }
        .padding(12)
    }

    private func priceField(_ model: String, _ keyPath: WritableKeyPath<PriceRowVM, String>) -> some SwiftUI.View {
        TextField("—", text: self.model.text(model, keyPath))
            .textFieldStyle(.roundedBorder)
            .frame(width: 76)
            .onSubmit { self.model.commitRow(model) }
    }

    /// 一行：左边灰色标签，右边控件。
    @ViewBuilder
    private func formRow<Content: SwiftUI.View>(_ label: String, @ViewBuilder content: () -> Content) -> some SwiftUI.View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 56, alignment: .leading)
            content()
        }
    }

    /// 灰色小字说明。
    private func note(_ text: String) -> some SwiftUI.View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .padding(.leading, 64)
    }
}
