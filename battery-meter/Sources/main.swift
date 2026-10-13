import AppKit
import IOKit.ps
import ServiceManagement

// MARK: - バッテリー情報

struct BatteryInfo {
    enum State {
        case discharging(minutes: Int?)   // nil = 計算中
        case charging(minutes: Int?)      // 満充電までの時間。nil = 計算中
        case charged                      // 満充電
        case acNotCharging(minutes: Int?) // 電源接続中だが充電していない。消費が上回る場合は残り稼働時間
    }

    var percent: Int
    var state: State
    /// minutes が macOS の推定値ではなく電流値からの自前計算かどうか
    var isEstimated = false
    var adapterWatts: Int?

    static func current(estimator: CurrentEstimator) -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else {
                continue
            }
            let percent = Int((Double(current) / Double(max) * 100).rounded())
            let onAC = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let isCharged = desc[kIOPSIsChargedKey] as? Bool ?? false

            func minutes(_ key: String) -> Int? {
                guard let m = desc[key] as? Int, m >= 0 else { return nil }
                return m
            }

            // macOS が時間を返さない場合（計算中・電源接続中なのに放電している等）は
            // スマートバッテリーの電流値と容量から自前で計算する
            let raw = estimator.sample()
            var estimated = false
            func orEstimate(_ m: Int?, _ fallback: Int?) -> Int? {
                if let m { return m }
                if fallback != nil { estimated = true }
                return fallback
            }

            let state: State
            if !onAC {
                state = .discharging(minutes: orEstimate(minutes(kIOPSTimeToEmptyKey), raw?.minutesToEmpty))
            } else if isCharging {
                state = .charging(minutes: orEstimate(minutes(kIOPSTimeToFullChargeKey), raw?.minutesToFull))
            } else if isCharged || percent >= 100 {
                state = .charged
            } else {
                state = .acNotCharging(minutes: orEstimate(nil, raw?.minutesToEmpty))
            }
            let watts = (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any])?[kIOPSPowerAdapterWattsKey] as? Int
            return BatteryInfo(percent: percent, state: state, isEstimated: estimated, adapterWatts: onAC ? watts : nil)
        }
        return nil
    }

    /// メニューバー用。時刻表示と見分けやすいよう "5h44m" 形式にする
    static func compact(_ m: Int) -> String {
        String(format: "%dh%02dm", m / 60, m % 60)
    }

    static func format(_ m: Int) -> String {
        String(format: "%d:%02d", m / 60, m % 60)
    }

    /// メニューバー下段の文字列
    var bottomLine: String {
        switch state {
        case .discharging(let m): return m.map { Self.compact($0) } ?? "計算中"
        case .charging(let m): return "⚡︎" + (m.map { Self.compact($0) } ?? "計算中")
        case .charged: return "満充電"
        case .acNotCharging(let m): return m.map { Self.compact($0) } ?? "接続中"
        }
    }

    /// 下段の先頭に付ける SF Symbol。電源接続を認識していることを示す
    var bottomSymbol: String? {
        if case .acNotCharging = state { return "powerplug.fill" }
        return nil
    }

    /// 電池アイコンを稲妻付きにするか（実際に充電されている／満充電のときのみ）
    var showsBolt: Bool {
        switch state {
        case .charging, .charged: return true
        case .discharging, .acNotCharging: return false
        }
    }

    /// メニュー内の詳細表示
    var detailLines: [String] {
        let adapter = adapterWatts.map { "電源：電源アダプタ（\($0)W）" } ?? "電源：電源アダプタ"
        let note = isEstimated ? "（電流値から推定）" : ""
        switch state {
        case .discharging(let m):
            return ["電源：バッテリー", m.map { "残り稼働時間：\(Self.format($0))\(note)" } ?? "残り稼働時間：計算中…"]
        case .charging(let m):
            return [adapter + " 充電中", m.map { "満充電まで：\(Self.format($0))\(note)" } ?? "満充電まで：計算中…"]
        case .charged:
            return [adapter, "満充電"]
        case .acNotCharging(let m):
            if let m {
                return [adapter + " 充電されていません", "出力不足のためバッテリーが減っています", "残り稼働時間：\(Self.format(m))\(note)"]
            }
            return [adapter + " 充電されていません", "充電保留中（最適化充電など）"]
        }
    }
}

// MARK: - 電流値からの残り時間推定

/// AppleSmartBattery の電流（mA）と残り容量（mAh）から時間を求める。
/// 低出力の電源（モバイルバッテリー等）では接続／切断が数秒ごとに切り替わり
/// macOS が時間を返さないため、その間も時間を表示する目的で使う。
/// 瞬間の電流は負荷で数倍変動するため、直近 window 秒の平均を使い、
/// minSpan 秒分のデータがたまるまでは結果を返さない（表示は「計算中」）。
final class CurrentEstimator {
    struct Result {
        var minutesToEmpty: Int?
        var minutesToFull: Int?
    }

    private let minCurrent = 50.0       // mA。これ未満は誤差とみなし計算しない
    private let window: TimeInterval = 120
    private let minSpan: TimeInterval = 30
    private let minInterval: TimeInterval = 4 // 通知が連続しても平均が偏らないよう間引く
    private var samples: [(date: Date, current: Double)] = []

    func sample(now: Date = Date()) -> Result? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let amperage = (prop("InstantAmperage") ?? prop("Amperage")) as? Int,
              let data = prop("BatteryData") as? [String: Any],
              let remaining = data["RemainingCapacity"] as? Int,
              let full = data["FullChargeCapacity"] as? Int, full > 0 else {
            return nil
        }

        guard let average = record(Double(amperage), at: now) else { return Result() }
        if average < 0 {
            return Result(minutesToEmpty: Int(Double(remaining) / -average * 60), minutesToFull: nil)
        }
        return Result(minutesToEmpty: nil, minutesToFull: Int(Double(max(full - remaining, 0)) / average * 60))
    }

    /// サンプルを記録し、十分なデータがあれば直近の平均電流を返す
    func record(_ current: Double, at now: Date) -> Double? {
        // 電流がほぼ 0、または充電⇔放電の向きが変わったら履歴を捨てる
        guard abs(current) >= minCurrent else {
            samples.removeAll()
            return nil
        }
        if let last = samples.last, (last.current < 0) != (current < 0) {
            samples.removeAll()
        }
        if let last = samples.last, now.timeIntervalSince(last.date) < minInterval {
            // 間引き：直近サンプルの値だけ更新する
            samples[samples.count - 1].current = current
        } else {
            samples.append((now, current))
        }
        samples.removeAll { now.timeIntervalSince($0.date) > window }

        guard let first = samples.first, now.timeIntervalSince(first.date) >= minSpan else { return nil }
        return samples.map(\.current).reduce(0, +) / Double(samples.count)
    }
}

// MARK: - メニューバー画像の描画

enum StatusImageRenderer {
    static let height: CGFloat = 22

    static func render(_ info: BatteryInfo) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        let top = NSAttributedString(string: "\(info.percent)%", attributes: attrs)
        let bottom = NSMutableAttributedString(string: info.bottomLine, attributes: attrs)
        if let name = info.bottomSymbol,
           let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold)) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attachment.bounds = NSRect(x: 0, y: -1, width: symbol.size.width, height: symbol.size.height)
            bottom.insert(NSAttributedString(string: "\u{2009}", attributes: attrs), at: 0)
            bottom.insert(NSAttributedString(attachment: attachment), at: 0)
            bottom.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: bottom.length))
        }
        let textWidth = ceil(max(top.size().width, bottom.size().width))

        let icon = batteryIcon(info)
        let iconSize = icon?.size ?? .zero
        let gap: CGFloat = 4
        let width = iconSize.width + gap + textWidth

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            if let icon {
                let y = (height - iconSize.height) / 2
                icon.draw(in: NSRect(x: 0, y: y, width: iconSize.width, height: iconSize.height))
            }
            let x = iconSize.width + gap
            let lineHeight = height / 2
            // 各行を半分の高さに収め、上下に詰めて配置する
            top.draw(in: NSRect(x: x, y: lineHeight - 1.5, width: textWidth, height: lineHeight + 1.5))
            bottom.draw(in: NSRect(x: x, y: -1, width: textWidth, height: lineHeight + 1.5))
            return true
        }
        // テンプレート画像にしてライト/ダーク・壁紙色に自動追従させる
        image.isTemplate = true
        return image
    }

    private static func batteryIcon(_ info: BatteryInfo) -> NSImage? {
        let name: String
        if info.showsBolt {
            name = "battery.100percent.bolt"
        } else {
            switch info.percent {
            case 88...: name = "battery.100percent"
            case 63..<88: name = "battery.75percent"
            case 38..<63: name = "battery.50percent"
            case 13..<38: name = "battery.25percent"
            default: name = "battery.0percent"
            }
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: "バッテリー")?
            .withSymbolConfiguration(config)
    }
}

// MARK: - アプリ本体

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var runLoopSource: CFRunLoopSource?
    private let menu = NSMenu()
    private let estimator = CurrentEstimator()
    private var lastInfo: BatteryInfo?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // ⌘ドラッグで移動した位置を再起動後も保持する
        statusItem.autosaveName = "BatteryMeter"
        menu.delegate = self
        statusItem.menu = menu

        registerLoginItemOnFirstLaunch()
        update()

        // 電源状態の変化（抜き差し・残量変化）を即時に受け取る
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue().update()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }

        // 残り時間の推定値は通知なしで変わるため定期更新も行う
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    private func update() {
        guard let button = statusItem.button else { return }
        lastInfo = BatteryInfo.current(estimator: estimator)
        if let info = lastInfo {
            button.image = StatusImageRenderer.render(info)
            button.title = ""
            button.toolTip = ([info.percent].map { "残量：\($0)%" } + info.detailLines).joined(separator: "\n")
        } else {
            button.image = nil
            button.title = "電池なし"
        }
    }

    // MARK: メニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let info = lastInfo {
            menu.addItem(disabledItem("残量：\(info.percent)%"))
            info.detailLines.forEach { menu.addItem(disabledItem($0)) }
        } else {
            menu.addItem(disabledItem("内蔵バッテリーが見つかりません"))
        }
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "バッテリー設定を開く…", action: #selector(openBatterySettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let login = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("BatteryMeter: login item toggle failed: \(error)")
        }
    }

    private func registerLoginItemOnFirstLaunch() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("BatteryMeter: login item register failed: \(error)")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
