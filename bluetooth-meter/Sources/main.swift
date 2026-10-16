import AppKit
import IOBluetooth
import ServiceManagement

// MARK: - デバイス情報

/// ペアリング済み Bluetooth デバイスの表示用スナップショット
struct DeviceInfo {
    let device: IOBluetoothDevice
    let name: String
    let isConnected: Bool
    /// 左右一体型（ヘッドホン等）の残量
    let single: Int?
    /// 左右独立型イヤホンの残量
    let left: Int?
    let right: Int?
    let caseLevel: Int?

    init(_ device: IOBluetoothDevice, levels: BatteryLevels?) {
        self.device = device
        name = device.name ?? device.addressString ?? "不明なデバイス"
        isConnected = device.isConnected()
        let levels = isConnected ? levels : nil
        single = levels?.single
        left = levels?.left
        right = levels?.right
        caseLevel = levels?.caseLevel
    }

    var hasBattery: Bool { single != nil || left != nil || right != nil }
    var isAudio: Bool { Int(device.deviceClassMajor) == kBluetoothDeviceClassMajorAudio }

    /// メニューバー上段に出す短い名前（例: "OpenRun Pro 2 by Shokz" → "OpenRun"）
    var shortName: String {
        let base = name.count > 10 ? (name.split(separator: " ").first.map(String.init) ?? name) : name
        return base.count > 10 ? String(base.prefix(9)) + "…" : base
    }

    /// メニューバー 2 段表示の文字列
    var statusLines: (top: String, bottom: String) {
        if left != nil || right != nil {
            return ("L " + Self.percent(left), "R " + Self.percent(right))
        }
        return (shortName, Self.percent(single))
    }

    /// メニュー項目の残量表記
    var batterySummary: String? {
        if left != nil || right != nil {
            var parts = ["L \(Self.percent(left))", "R \(Self.percent(right))"]
            if let caseLevel { parts.append("ケース \(caseLevel)%") }
            return parts.joined(separator: "  ")
        }
        return single.map { "\($0)%" }
    }

    static func percent(_ v: Int?) -> String { v.map { "\($0)%" } ?? "--" }

    var symbolName: String {
        let lower = name.lowercased()
        switch Int(device.deviceClassMajor) {
        case kBluetoothDeviceClassMajorAudio:
            if lower.contains("airpods") { return "airpods" }
            return (left != nil || right != nil) ? "earbuds" : "headphones"
        case kBluetoothDeviceClassMajorPeripheral:
            if lower.contains("controller") || lower.contains("dualshock") || lower.contains("dualsense") {
                return "gamecontroller.fill"
            }
            if lower.contains("mouse") || lower.contains("trackpad") { return "computermouse.fill" }
            return "keyboard"
        case kBluetoothDeviceClassMajorPhone:
            return "iphone"
        default:
            return "antenna.radiowaves.left.and.right"
        }
    }

    static func all(levels: [String: BatteryLevels]) -> [DeviceInfo] {
        ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).map {
            DeviceInfo($0, levels: $0.addressString.flatMap { levels[$0] })
        }
    }
}

// MARK: - 残量の取得

/// 1 台分の残量（%）。未取得の値は nil
struct BatteryLevels: Codable {
    var single: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?
}

/// 残量は IOBluetoothDevice の非公開プロパティから取得する。
/// 同一プロセス内ではプロセス起動時に読み込んだ値が更新されず、切断→再接続後は 0 のままになる
/// （2026-10-12 実測）。そのため取得のたびに自分自身を `--dump-battery` 付きで別プロセス起動し、
/// 最新値を JSON で受け取る。将来の macOS で取得できなくなった場合は残量を表示しないだけで動作は継続する。
enum BatteryReader {
    static let dumpArgument = "--dump-battery"

    /// 子プロセス側：接続中デバイスの残量を {アドレス: BatteryLevels} の JSON で標準出力へ書く
    static func dump() {
        var result: [String: BatteryLevels] = [:]
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] where device.isConnected() {
            // 0 は「未取得」を意味する
            func level(_ key: String) -> Int? {
                guard device.responds(to: NSSelectorFromString(key)),
                      let v = device.value(forKey: key) as? Int, v > 0, v <= 100 else { return nil }
                return v
            }
            guard let address = device.addressString else { continue }
            let levels = BatteryLevels(single: level("batteryPercentSingle"), left: level("batteryPercentLeft"),
                                       right: level("batteryPercentRight"), caseLevel: level("batteryPercentCase"))
            if levels.single != nil || levels.left != nil || levels.right != nil {
                result[address] = levels
            }
        }
        if let data = try? JSONEncoder().encode(result) {
            FileHandle.standardOutput.write(data)
        }
    }

    /// 親プロセス側：子プロセスを起動して残量を読む（バックグラウンドで実行し、完了時にメインスレッドで通知）
    static func read(completion: @escaping ([String: BatteryLevels]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var levels: [String: BatteryLevels] = [:]
            if let path = Bundle.main.executablePath {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = [dumpArgument]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    // 万一応答しない場合に備えて 5 秒で打ち切る
                    let deadline = DispatchTime.now() + 5
                    DispatchQueue.global().asyncAfter(deadline: deadline) {
                        if process.isRunning { process.terminate() }
                    }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    levels = (try? JSONDecoder().decode([String: BatteryLevels].self, from: data)) ?? [:]
                } catch {
                    NSLog("BluetoothMeter: battery reader failed: \(error)")
                }
            }
            DispatchQueue.main.async { completion(levels) }
        }
    }
}

// MARK: - メニューバー画像の描画

enum StatusImageRenderer {
    static let height: CGFloat = 22
    /// メニューバー項目の左右余白の合計
    static let horizontalPadding: CGFloat = 10

    /// 未接続時：Bluetooth ロゴのみ
    static func renderIdle() -> NSImage {
        let size = NSSize(width: 12, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            // Bluetooth のルーン（ᛒ）を線で描く。幅 7pt × 高さ 13pt を中央に配置
            let w: CGFloat = 7, h: CGFloat = 13
            let ox = (size.width - w) / 2, oy = (size.height - h) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * w, y: oy + y * h) }
            let path = NSBezierPath()
            path.move(to: p(0, 0.25))
            path.line(to: p(1, 0.75))
            path.line(to: p(0.5, 1))
            path.line(to: p(0.5, 0))
            path.line(to: p(1, 0.25))
            path.line(to: p(0, 0.75))
            path.lineWidth = 1.4
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 接続中：デバイスアイコン＋2段テキスト
    static func render(_ info: DeviceInfo) -> NSImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        let lines = info.statusLines
        let top = NSAttributedString(string: lines.top, attributes: attrs)
        let bottom = NSAttributedString(string: lines.bottom, attributes: attrs)
        let textWidth = ceil(max(top.size().width, bottom.size().width))

        let icon = NSImage(systemSymbolName: info.symbolName, accessibilityDescription: info.name)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        let iconSize = icon?.size ?? .zero
        let gap: CGFloat = 4
        let width = iconSize.width + gap + textWidth

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            if let icon {
                icon.draw(in: NSRect(x: 0, y: (height - iconSize.height) / 2,
                                     width: iconSize.width, height: iconSize.height))
            }
            let x = iconSize.width + gap
            let lineHeight = height / 2
            top.draw(in: NSRect(x: x, y: lineHeight - 1.5, width: textWidth, height: lineHeight + 1.5))
            bottom.draw(in: NSRect(x: x, y: -1, width: textWidth, height: lineHeight + 1.5))
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - アプリ本体

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var levels: [String: BatteryLevels] = [:]
    private var isMenuOpen = false
    private var lastRepair = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        installStatusItem()

        registerLoginItemOnFirstLaunch()

        // 接続・切断を即時に反映する
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        // 残量は接続後しばらくしてから届き、通知もないため定期的に読み直す
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshBattery()
        }
        update()
        refreshBattery()
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let address = device.addressString, disconnectNotifications[address] == nil {
            disconnectNotifications[address] = device.register(
                forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        }
        update()
        // 残量は接続直後には未取得のことが多いため、間隔を空けて数回取得する
        for delay in [2.0, 8.0, 20.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refreshBattery() }
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        if let address = device.addressString { disconnectNotifications[address] = nil }
        update()
    }

    /// メニューバーに出すデバイス：残量の取れる接続中デバイスのうち、オーディオ機器を優先
    private func primaryDevice(_ devices: [DeviceInfo]) -> DeviceInfo? {
        let candidates = devices.filter { $0.isConnected && $0.hasBattery }
        return candidates.first(where: \.isAudio) ?? candidates.first
    }

    private func refreshBattery() {
        BatteryReader.read { [weak self] levels in
            self?.levels = levels
            self?.update()
        }
    }

    private func update() {
        guard let button = statusItem.button else { return }
        let devices = DeviceInfo.all(levels: levels)
        let image = primaryDevice(devices).map(StatusImageRenderer.render) ?? StatusImageRenderer.renderIdle()
        button.image = image
        // variableLength のままだと、幅の広い画像から狭い画像へ差し替えても項目幅が縮まないことがある
        // （2026-10-15 実測：イヤホン切断後もロゴの右に空白が残った）。画像幅に合わせて明示的に設定する
        statusItem.length = image.size.width + StatusImageRenderer.horizontalPadding
        // 反映はメニューバー側で非同期に行われるため、少し待ってから幅の詰まりを確認する
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.repairIfStuck() }
        let connected = devices.filter(\.isConnected)
        button.toolTip = connected.isEmpty
            ? "Bluetooth：接続中のデバイスなし"
            : connected.map { [$0.name, $0.batterySummary].compactMap { $0 }.joined(separator: "  ") }
                .joined(separator: "\n")
    }

    // MARK: メニューバー項目

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "BluetoothMeter"  // 再作成しても並び位置が保たれる
        statusItem.menu = menu
    }

    /// length を明示しても、長時間起動後などに項目ウィンドウの幅が追従しないことがある。
    /// - 広いまま残る：ロゴの右に空白ができる（2026-10-15 実測、再起動で解消）
    /// - 狭いまま残る：テキストが右隣の項目（Wi-Fi 等）に重なって描かれる（2026-10-16 実測）
    /// 正常時のウィンドウ幅は length + 6pt 程度なので、そこから明らかに外れていれば項目を作り直す。
    private func repairIfStuck() {
        guard !isMenuOpen, let window = statusItem.button?.window else { return }
        let excess = window.frame.width - statusItem.length
        guard excess > 12 || excess < -2 else { return }
        // 作り直しても直らない場合に繰り返さないよう、間隔を空ける
        guard Date().timeIntervalSince(lastRepair) > 60 else { return }
        lastRepair = Date()
        NSLog("BluetoothMeter: status item stuck (window \(window.frame.width)pt, length \(statusItem.length)pt); recreating")
        NSStatusBar.system.removeStatusItem(statusItem)
        installStatusItem()
        update()
    }

    // MARK: メニュー

    func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        update()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let devices = DeviceInfo.all(levels: levels)

        if IOBluetoothHostController.default()?.powerState != kBluetoothHCIPowerStateON {
            menu.addItem(disabledItem("Bluetooth はオフです"))
        } else if devices.isEmpty {
            menu.addItem(disabledItem("ペアリング済みのデバイスがありません"))
        } else {
            // 接続中を上に並べる
            for info in devices.sorted(by: { $0.isConnected && !$1.isConnected }) {
                let item = NSMenuItem(title: info.name, action: #selector(toggleConnection(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = info.device
                item.state = info.isConnected ? .on : .off
                item.image = NSImage(systemSymbolName: info.symbolName, accessibilityDescription: nil)
                if let battery = info.batterySummary {
                    item.attributedTitle = menuTitle(info.name, battery)
                }
                item.toolTip = info.isConnected ? "クリックで切断" : "クリックで接続"
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Bluetooth設定を開く…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let login = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func menuTitle(_ name: String, _ battery: String) -> NSAttributedString {
        let title = NSMutableAttributedString(string: name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(string: "   " + battery, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return title
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleConnection(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? IOBluetoothDevice else { return }
        if device.isConnected() {
            device.closeConnection()
            update()
        } else {
            // target を渡すと非同期接続になり、完了時に connectionComplete が呼ばれる
            let result = device.openConnection(self)
            if result != kIOReturnSuccess {
                NSLog("BluetoothMeter: openConnection failed: \(result)")
            }
        }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        if status != kIOReturnSuccess {
            NSLog("BluetoothMeter: connection to \(device.name ?? "?") failed: \(status)")
        }
        update()
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
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
            NSLog("BluetoothMeter: login item toggle failed: \(error)")
        }
    }

    private func registerLoginItemOnFirstLaunch() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("BluetoothMeter: login item register failed: \(error)")
        }
    }
}

if CommandLine.arguments.contains(BatteryReader.dumpArgument) {
    BatteryReader.dump()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
