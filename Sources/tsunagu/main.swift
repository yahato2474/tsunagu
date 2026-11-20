import AppKit

// Tsunagu: Tailscale の端末一覧をメニューバーに出し、画面共有・SSH・Taildrop を1クリックで行う。
// 端末の情報は Tailscale 本体の CLI (`status --json`) から毎回取り直す。

let tailscalePath = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

// RDP が使えない Windows (Home エディションなど) は RustDesk で繋ぐ。
// Tailscale の IP へ直接つなぐので、相手側の RustDesk で「直接 IP アクセスを有効化」が必要。
let rustdeskHosts: Set<String> = ["lg-gram"]

struct Device {
    let name: String       // MagicDNS 名の先頭ラベル (例: mac-mini)
    let dnsName: String    // 末尾のドットを除いた FQDN
    let ip: String
    let os: String
    let online: Bool
    let lastSeen: Date?
    let canReceiveFiles: Bool
}

struct Tailnet {
    var running = false
    var me: Device?
    var peers: [Device] = []
    var error: String?
}

// MARK: - Tailscale CLI

@discardableResult
func runTailscale(_ args: [String]) -> (status: Int32, out: Data, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tailscalePath)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return (-1, Data(), error.localizedDescription) }
    // 先に読み切ってから待つ (パイプが詰まって止まるのを防ぐ)
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, outData, String(data: errData, encoding: .utf8) ?? "")
}

func parseDevice(_ d: [String: Any]) -> Device? {
    guard let dns = (d["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
          !dns.isEmpty else { return nil }
    let ips = d["TailscaleIPs"] as? [String] ?? []
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var seen = (d["LastSeen"] as? String).flatMap { iso.date(from: $0) }
    if let s = seen, s.timeIntervalSince1970 < 0 { seen = nil }   // 0001-01-01 は「値なし」
    return Device(
        name: String(dns.split(separator: ".").first ?? ""),
        dnsName: dns,
        ip: ips.first(where: { !$0.contains(":") }) ?? ips.first ?? "",
        os: (d["OS"] as? String ?? "").lowercased(),
        online: d["Online"] as? Bool ?? false,
        lastSeen: seen,
        canReceiveFiles: (d["TaildropTarget"] as? Int) == 1   // 1 = 送信可能
    )
}

func fetchTailnet() -> Tailnet {
    var t = Tailnet()
    guard FileManager.default.isExecutableFile(atPath: tailscalePath) else {
        t.error = "Tailscale.app が見つかりません"
        return t
    }
    let r = runTailscale(["status", "--json"])
    guard let json = try? JSONSerialization.jsonObject(with: r.out) as? [String: Any] else {
        t.error = "Tailscale から状態を取得できません"
        return t
    }
    t.running = (json["BackendState"] as? String) == "Running"
    t.me = (json["Self"] as? [String: Any]).flatMap(parseDevice)
    let peers = (json["Peer"] as? [String: Any] ?? [:]).values.compactMap { ($0 as? [String: Any]).flatMap(parseDevice) }
    t.peers = peers.sorted { $0.name < $1.name }
    return t
}

// MARK: - メニュー部品

final class ClosureItem: NSMenuItem {
    private var handler: (() -> Void)?
    convenience init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.handler = handler
        if let symbol { self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }
    @objc private func fire() { handler?() }
}

func label(_ title: String) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
}

func deviceSymbol(_ d: Device) -> String {
    switch d.os {
    case "macos": return d.name.contains("air") || d.name.contains("book") ? "laptopcomputer" : "macmini"
    case "ios": return "iphone"
    case "windows": return "pc"
    default: return "server.rack"
    }
}

func deviceImage(_ d: Device) -> NSImage? {
    let color: NSColor = d.online ? .systemGreen : .tertiaryLabelColor
    let conf = NSImage.SymbolConfiguration(paletteColors: [color])
    return NSImage(systemSymbolName: deviceSymbol(d), accessibilityDescription: nil)?.withSymbolConfiguration(conf)
}

func relative(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "ja_JP")
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
}

func copyText(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

func openURL(_ urlString: String) {
    if let u = URL(string: urlString) { NSWorkspace.shared.open(u) }
}

// MARK: - アプリ本体

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon()
        menu.delegate = self
        statusItem.menu = menu
    }

    func setIcon() {
        let img = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Tsunagu")
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: "Tsunagu")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.title = ""
    }

    // メニューを開くたびに最新の状態で作り直す
    func menuNeedsUpdate(_ menu: NSMenu) {
        build(menu, from: fetchTailnet())
    }

    func build(_ menu: NSMenu, from t: Tailnet) {
        menu.removeAllItems()
        if let e = t.error {
            menu.addItem(label(e))
        } else if !t.running {
            menu.addItem(label("Tailscale は停止中です"))
        }

        let online = t.peers.filter { $0.online }
        let offline = t.peers.filter { !$0.online }

        for d in online {
            let item = NSMenuItem(title: d.name, action: nil, keyEquivalent: "")
            item.image = deviceImage(d)
            item.submenu = submenu(for: d)
            menu.addItem(item)
        }
        if online.isEmpty && t.error == nil && t.running {
            menu.addItem(label("オンラインの端末はありません"))
        }

        if !offline.isEmpty {
            menu.addItem(.separator())
            menu.addItem(label("オフライン"))
            for d in offline {
                let seen = d.lastSeen.map { "  \(relative($0))" } ?? ""
                let item = NSMenuItem(title: d.name + seen, action: nil, keyEquivalent: "")
                item.image = deviceImage(d)
                item.submenu = submenu(for: d)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        if let me = t.me {
            menu.addItem(ClosureItem("この Mac: \(me.name)  \(me.ip)") { copyText(me.ip) })
        }
        menu.addItem(ClosureItem("Tailscale を開く") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app"))
        })
        menu.addItem(ClosureItem("Tsunagu を終了") { NSApp.terminate(nil) })
    }

    func submenu(for d: Device) -> NSMenu {
        let m = NSMenu()
        if d.online {
            switch d.os {
            case "macos":
                m.addItem(ClosureItem("画面共有", symbol: "rectangle.on.rectangle") { openURL("vnc://\(d.dnsName)") })
                m.addItem(ClosureItem("SSH (ターミナル)", symbol: "terminal") { openURL("ssh://\(d.dnsName)") })
            case "windows":
                if rustdeskHosts.contains(d.name) {
                    m.addItem(ClosureItem("リモートデスクトップ (RustDesk)", symbol: "rectangle.on.rectangle") {
                        openURL("rustdesk://connection/new/\(d.ip)")
                    })
                } else {
                    m.addItem(ClosureItem("リモートデスクトップ", symbol: "rectangle.on.rectangle") {
                        openURL("rdp://full%20address=s:\(d.ip):3389")
                    })
                }
                m.addItem(ClosureItem("SSH (ターミナル)", symbol: "terminal") { openURL("ssh://\(d.dnsName)") })
            case "ios":
                break
            default:
                m.addItem(ClosureItem("SSH (ターミナル)", symbol: "terminal") { openURL("ssh://\(d.dnsName)") })
            }
            if d.canReceiveFiles {
                m.addItem(ClosureItem("ファイルを送る (Taildrop)…", symbol: "paperplane") { [weak self] in self?.sendFiles(to: d) })
            }
            if d.os != "ios" {
                m.addItem(ClosureItem("ブラウザで開く", symbol: "safari") { openURL("https://\(d.dnsName)") })
            }
            m.addItem(.separator())
        }
        m.addItem(ClosureItem("IP をコピー  \(d.ip)", symbol: "doc.on.doc") { copyText(d.ip) })
        m.addItem(ClosureItem("名前をコピー  \(d.dnsName)", symbol: "doc.on.doc") { copyText(d.dnsName) })
        return m
    }

    // MARK: Taildrop

    func sendFiles(to d: Device) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false   // Tailscale 本体がフォルダ送信に非対応
        panel.message = "\(d.name) に送るファイルを選択"
        panel.prompt = "送る"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let paths = panel.urls.map { $0.path }

        statusItem.button?.image = nil
        statusItem.button?.title = "送信中…"
        DispatchQueue.global().async {
            let r = runTailscale(["file", "cp"] + paths + ["\(d.ip):"])
            DispatchQueue.main.async {
                if r.status == 0 {
                    NSSound(named: "Glass")?.play()
                    self.statusItem.button?.title = "✓ 送信完了"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.setIcon() }
                } else {
                    self.setIcon()
                    let a = NSAlert()
                    a.alertStyle = .warning
                    a.messageText = "\(d.name) へ送信できませんでした"
                    a.informativeText = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                    NSApp.activate(ignoringOtherApps: true)
                    a.runModal()
                }
            }
        }
    }
}

// MARK: - 起動

func dump(_ menu: NSMenu, indent: String = "") {
    for i in menu.items {
        print(indent + (i.isSeparatorItem ? "────" : i.title) + (i.isEnabled ? "" : "  (見出し)"))
        if let s = i.submenu { dump(s, indent: indent + "    ") }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()

if CommandLine.arguments.contains("--dump") {
    // 動作確認用: 実際のメニューと同じ内容を文字で出して終了する
    let m = NSMenu()
    m.autoenablesItems = false
    delegate.build(m, from: fetchTailnet())
    dump(m)
    exit(0)
}

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
