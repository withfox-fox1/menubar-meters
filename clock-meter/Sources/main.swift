import AppKit
import ServiceManagement

// MARK: - メニューバー画像の描画

/// 上段に日付（10/12(月)）、下段に 24 時間表記の時刻（12:00）を縦 2 段で描く
enum StatusImageRenderer {
    static let height: CGFloat = 22

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E)"
        return f
    }()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func render(_ date: Date) -> NSImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        let top = NSAttributedString(string: dateFormatter.string(from: date), attributes: attrs)
        let bottom = NSAttributedString(string: timeFormatter.string(from: date), attributes: attrs)
        let textWidth = ceil(max(top.size().width, bottom.size().width))

        // 左隣の項目（バッテリー表示）と見分けやすくするため、左端に縦の区切り線を引く
        let separatorWidth: CGFloat = 2
        let separatorLeading: CGFloat = 5  // バッテリー表示と線の間
        let separatorGap: CGFloat = 7      // 線と日付・時刻の間
        let textX = separatorLeading + separatorWidth + separatorGap
        let width = textX + textWidth

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: separatorLeading, y: 3, width: separatorWidth, height: height - 6), xRadius: 1, yRadius: 1).fill()

            let lineHeight = height / 2
            top.draw(in: NSRect(x: textX, y: lineHeight - 1.5, width: textWidth, height: lineHeight + 1.5))
            bottom.draw(in: NSRect(x: textX, y: -1, width: textWidth, height: lineHeight + 1.5))
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "ClockMeter"
        menu.delegate = self
        statusItem.menu = menu

        registerLoginItemOnFirstLaunch()
        update()
        scheduleNextMinute()

        // スリープ復帰・時刻変更・タイムゾーン変更時はタイマーがずれるため即時に合わせ直す
        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            center.addObserver(self, selector: #selector(resync), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(resync), name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// 次の「分」の 0 秒ちょうどに更新し、以降も分の切り替わりに合わせる
    private func scheduleNextMinute() {
        timer?.invalidate()
        let now = Date()
        let next = Calendar.current.nextDate(after: now, matching: DateComponents(second: 0),
                                             matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            self?.update()
            self?.scheduleNextMinute()
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func resync() {
        update()
        scheduleNextMinute()
    }

    private func update() {
        let now = Date()
        statusItem.button?.image = StatusImageRenderer.render(now)
        statusItem.button?.toolTip = Self.fullFormatter.string(from: now)
    }

    static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日(EEEE) HH:mm"
        return f
    }()

    // MARK: メニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let full = NSMenuItem(title: Self.fullFormatter.string(from: Date()), action: nil, keyEquivalent: "")
        full.isEnabled = false
        menu.addItem(full)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "日付と時刻の設定を開く…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let login = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension") {
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
            NSLog("ClockMeter: login item toggle failed: \(error)")
        }
    }

    private func registerLoginItemOnFirstLaunch() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("ClockMeter: login item register failed: \(error)")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
