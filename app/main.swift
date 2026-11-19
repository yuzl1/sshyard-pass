import Cocoa

struct HostEntry: Decodable {
    let id: String?
    let name: String?
    let address: String?
    let port: Int?
    let user: String?
    let group: String?
    let auth: String?
}

struct HostFile: Decodable {
    let hosts: [HostEntry]
}

struct Item {
    let address: String
    let port: Int
    let user: String
    let name: String
    let group: String
    let auth: String

    var searchBlob: String {
        [address, user, name, group].joined(separator: " ").lowercased()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var table: NSTableView!
    private var scrollView: NSScrollView!
    private var search: NSSearchField!
    private var status: NSTextField!
    private var fetchButton: NSButton!

    private let hostsPath = NSHomeDirectory() + "/Library/Application Support/SSHYard/hosts.json"

    /// Prefer the copy shipped inside the app bundle, fall back to the CLI install.
    private var toolPath: String {
        if let bundled = Bundle.main.url(forResource: "sshyard-pass", withExtension: nil) {
            return bundled.path
        }
        return NSHomeDirectory() + "/.local/bin/sshyard-pass"
    }

    private var items: [Item] = []
    private var filtered: [Item] = []
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        loadHosts()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(search)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(search)
        return true
    }

    // MARK: - UI

    private func buildWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 500, height: 580)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SSHYard 密码获取器"
        window.minSize = NSSize(width: 420, height: 360)
        window.center()
        window.isReleasedWhenClosed = false

        let root = NSView()
        window.contentView = root

        search = NSSearchField()
        search.placeholderString = "搜索 IP、用户名、名称或分组"
        search.font = NSFont.systemFont(ofSize: 13)
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .controlBackgroundColor
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .inset

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(fetchSelected)

        scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 11.5)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false

        fetchButton = NSButton(title: "获取密码", target: self, action: #selector(fetchSelected))
        fetchButton.bezelStyle = .rounded
        fetchButton.keyEquivalent = "\r"
        fetchButton.controlSize = .large
        fetchButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(search)
        root.addSubview(scrollView)
        root.addSubview(status)
        root.addSubview(fetchButton)

        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),

            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            status.trailingAnchor.constraint(equalTo: fetchButton.leadingAnchor, constant: -12),

            fetchButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            fetchButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            fetchButton.widthAnchor.constraint(equalToConstant: 110),
        ])
    }

    // MARK: - Data

    private func loadHosts() {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: hostsPath))
            let file = try JSONDecoder().decode(HostFile.self, from: data)
            items = file.hosts.compactMap { entry in
                guard let address = entry.address, !address.isEmpty else { return nil }
                return Item(
                    address: address,
                    port: entry.port ?? 22,
                    user: entry.user ?? "",
                    name: entry.name ?? "",
                    group: entry.group ?? "",
                    auth: entry.auth ?? "password"
                )
            }
            .sorted {
                $0.address == $1.address ? $0.user < $1.user : $0.address < $1.address
            }
            applyFilter()
            if items.isEmpty {
                setStatus("SSHYard 里还没有主机", error: true)
            } else {
                setStatus("共 \(items.count) 台主机，回车或双击获取密码")
            }
        } catch {
            setStatus("读取 SSHYard 主机列表失败：\(error.localizedDescription)", error: true)
        }
    }

    private func applyFilter() {
        let needle = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = needle.isEmpty ? items : items.filter { $0.searchBlob.contains(needle) }
        table.reloadData()
        if filtered.isEmpty, !items.isEmpty {
            setStatus("没有匹配的主机")
        } else if !filtered.isEmpty, !needle.isEmpty {
            setStatus("匹配 \(filtered.count) 台，回车或双击获取密码")
        } else if !items.isEmpty {
            setStatus("共 \(items.count) 台主机，回车或双击获取密码")
        }
        if !filtered.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.attributedStringValue = render(filtered[row])
        return cell
    }

    private func render(_ item: Item) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium)
        let small = NSFont.systemFont(ofSize: 11.5)
        let result = NSMutableAttributedString()

        let host = item.port == 22 ? item.address : "\(item.address):\(item.port)"
        result.append(NSAttributedString(
            string: host,
            attributes: [.font: mono, .foregroundColor: NSColor.labelColor]
        ))
        result.append(NSAttributedString(
            string: "  " + item.user,
            attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]
        ))

        var tail = "   " + item.name
        if item.auth == "key" {
            tail += "  · 私钥"
        } else if item.auth == "ask" {
            tail += "  · 每次询问"
        }
        result.append(NSAttributedString(
            string: tail,
            attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]
        ))

        if !item.group.isEmpty {
            result.append(NSAttributedString(
                string: "  · \(item.group)",
                attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor]
            ))
        }
        return result
    }

    // MARK: - Actions

    @objc private func fetchSelected() {
        guard !busy else { return }
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else {
            setStatus("先选一台主机", error: true)
            return
        }
        let item = filtered[row]
        let query = item.user.isEmpty ? item.address : "\(item.user)@\(item.address)"

        busy = true
        fetchButton.isEnabled = false
        setStatus("正在读取 \(query) 的密码…")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = [query, "--copy"]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        process.terminationHandler = { [weak self] proc in
            let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self?.finish(proc.terminationStatus, stdout: stdout, stderr: stderr, query: query)
            }
        }

        do {
            try process.run()
        } catch {
            busy = false
            fetchButton.isEnabled = true
            setStatus("启动解密程序失败：\(error.localizedDescription)", error: true)
        }
    }

    private func finish(_ code: Int32, stdout: String, stderr: String, query: String) {
        busy = false
        fetchButton.isEnabled = true

        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if code != 0 {
            setStatus(err.isEmpty ? "读取失败（退出码 \(code)）" : err, error: true)
            NSSound.beep()
            return
        }
        if out.contains("已复制") {
            setStatus("✓ \(out)", error: false, success: true)
        } else if out.isEmpty {
            setStatus("没有返回内容", error: true)
        } else {
            setStatus(out, error: false)
        }
    }

    private func setStatus(_ text: String, error: Bool = false, success: Bool = false) {
        status.stringValue = text
        if error {
            status.textColor = .systemRed
        } else if success {
            status.textColor = .systemGreen
        } else {
            status.textColor = .secondaryLabelColor
        }
    }
}

extension AppDelegate: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            fetchSelected()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            window.close()
            return true
        }
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu()
menu.addItem(NSMenuItem(title: "退出 SSHYard 密码获取器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
let appMenuItem = NSMenuItem()
appMenuItem.submenu = menu
let mainMenu = NSMenu()
mainMenu.addItem(appMenuItem)
app.mainMenu = mainMenu
app.run()
