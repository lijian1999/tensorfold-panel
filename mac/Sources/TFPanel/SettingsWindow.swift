// 设置窗口（接口约定 9.5）：三页「引擎 / 费用 / 副屏」，内容是 SwiftUI。
// 表的数据、各输入框的文字放在 SettingsModel 里，SwiftUI 视图只读写它。
import AppKit
import PanelCore
import SwiftUI

enum SettingsPage: String, CaseIterable { case engine, price, screen }

/// 费用表一行的编辑状态（单价表行 + 三个输入框的文字 + 是否填错）。
struct PriceRowVM: Identifiable, Equatable {
    let model: String
    var present: Bool
    var input: String
    var cached: String
    var output: String
    var invalid: Bool

    var id: String { model }
}

@MainActor
final class SettingsModel: ObservableObject {
    private let controller: AppController

    // 引擎页
    @Published var engineChoice = "oMLX"      // 这一版只有 oMLX 一项
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
        addressText = s.address
        keyMode = s.keyMode
        manualKeyText = s.manualKey
        screenNameText = s.screenName
        statusNote = controller.issue.message ?? "已连接"
        currencyText = s.currency
        rebuildRows(keeping: [])
    }

    /// 打开窗口时从设置重新取各输入框的文字（保留已有的行编辑内容）。
    func reload() {
        let s = controller.settings
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

    /// 按当前模型列表 + knownModels + 已填单价重排行；keeping 里同名模型保留已输入的文字。
    private func rebuildRows(keeping: [PriceRowVM]) {
        var edits: [String: PriceRowVM] = [:]
        for r in keeping { edits[r.model] = r }
        rows = priceRows(current: controller.modelIDs,
                         known: controller.settings.knownModels,
                         prices: controller.settings.prices).map { row in
            if var e = edits[row.model] {
                e.present = row.present
                return e
            }
            func text(_ keyPath: KeyPath<ModelPrice, Double>) -> String {
                guard let p = row.price else { return "" }
                return priceText(p[keyPath: keyPath])
            }
            return PriceRowVM(model: row.model, present: row.present,
                              input: text(\.input), cached: text(\.cached), output: text(\.output),
                              invalid: false)
        }
    }

    /// 三个单价输入框的绑定（改动先只留在界面上，按回车或关窗时生效）。
    func text(_ model: String, _ keyPath: WritableKeyPath<PriceRowVM, String>) -> Binding<String> {
        Binding(
            get: { self.rows.first { $0.model == model }?[keyPath: keyPath] ?? "" },
            set: { v in
                guard let i = self.rows.firstIndex(where: { $0.model == model }) else { return }
                self.rows[i][keyPath: keyPath] = v
                self.rows[i].invalid = false   // 重新编辑时先撤掉红字
            }
        )
    }

    // MARK: - 马上生效的（分段控件、删除按钮）

    func applyKeyMode(_ mode: KeyMode) {
        keyMode = mode
        controller.settings.keyMode = mode
        controller.settingsChanged()
    }

    /// 换货币：只换符号和文字，数字不按汇率换算；立刻生效
    func applyCurrency(_ symbol: String) {
        currencyText = symbol
        controller.settings.currency = symbol
        controller.settingsChanged()
    }

    /// 费用页的说明文字，跟着货币走
    var currencyNote: String {
        currencyName(currencyText) + " / 百万 token。自己查了 API 价格填；没填的模型不算进今日费用"
    }

    func forget(_ model: String) {
        controller.settings.forgetModel(model)
        rebuildRows(keeping: rows.filter { $0.model != model })
        controller.settingsChanged()
    }

    // MARK: - 输入框生效（按回车、关窗时）

    /// 一行的三个框按 parsePrice 的结果生效：valid 写入；empty 删掉；invalid 不写、标红。
    func commitRow(_ model: String) {
        guard let i = rows.firstIndex(where: { $0.model == model }) else { return }
        let r = rows[i]
        switch parsePrice(input: r.input, cached: r.cached, output: r.output) {
        case .valid(let p):
            controller.settings.prices[model] = p
            rows[i].invalid = false
        case .empty:
            controller.settings.prices.removeValue(forKey: model)
            rows[i].invalid = false
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

    /// 关窗时把所有输入框写进设置，settingsChanged() 调一次。
    func commitAll() {
        let s = controller.settings
        let addr = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !addr.isEmpty { s.address = addr }
        s.manualKey = manualKeyText
        let name = screenNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { s.screenName = name }
        var prices = s.prices
        for (i, r) in rows.enumerated() {
            switch parsePrice(input: r.input, cached: r.cached, output: r.output) {
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
            win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
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

    /// 关闭窗口时把各输入框写进设置。
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
        .frame(width: 380)
    }

    private var enginePage: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 8) {
            formRow("引擎") {
                Picker("", selection: $model.engineChoice) {
                    Text("oMLX").tag("oMLX")
                }
                .labelsHidden()
                .frame(width: 160)
            }
            note("这一版只有 oMLX；以后接入的引擎会出现在这里")
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
                note("读 ~/.omlx/settings.json 里的 auth.api_key")
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
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                GridRow {
                    Text("模型").font(.callout).foregroundColor(.secondary)
                    Text("输入").font(.callout).foregroundColor(.secondary)
                    Text("缓存命中").font(.callout).foregroundColor(.secondary)
                    Text("输出").font(.callout).foregroundColor(.secondary)
                    Text(" ")
                }
                Divider()
                ForEach(model.rows) { row in
                    GridRow {
                        Text(row.model)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(row.present ? .primary : .secondary)
                        priceField(row.model, \.input)
                        priceField(row.model, \.cached)
                        priceField(row.model, \.output)
                        if !row.present {
                            Button("删除") { model.forget(row.model) }
                                .buttonStyle(.borderless)
                                .font(.callout)
                        } else {
                            Text(" ")
                        }
                    }
                    if row.invalid {
                        GridRow {
                            Text("三项都要填，填不小于 0 的数")
                                .font(.callout)
                                .foregroundColor(.red)
                                .gridCellColumns(5)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .padding(12)
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
            .frame(width: 64)
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
