// UCMenu — 通用控制菜单栏常驻开关 + 显示器排列快照
//
// 设计要点：
//   · 菜单打开时**不做任何 IO**，只用后台轮询好的缓存渲染，保证点开即出
//   · 显示器排列用「快照 + 一键还原」，不做拖拽画布
//   · 通用控制下的 iPad 不是显示器，无法参与排列；它的逻辑位置只能靠
//     备份/还原 UniversalControl 的配置（可选，默认关）
//
// 编译：./build.sh

import AppKit
import CoreGraphics
import Foundation

// ─────────────────────────── 路径 ───────────────────────────

let kUCApp = "/System/Library/CoreServices/UniversalControl.app"
let kUCPattern = "UniversalControl.app/Contents/MacOS/UniversalControl"
let kSettingsURL = "x-apple.systempreferences:com.apple.Displays-Settings.extension?sidecarSection"

let home = NSHomeDirectory() as NSString
let cfgDir = home.appendingPathComponent(".config/uc")
let cfgFile = (cfgDir as NSString).appendingPathComponent("menu.conf")
let arrangeFile = (cfgDir as NSString).appendingPathComponent("arrange.tsv")
let restoreUCFlag = (cfgDir as NSString).appendingPathComponent("restore-uc")
let ucBin = home.appendingPathComponent("bin/uc")

// ─────────────────────────── 配置 ───────────────────────────

struct Cfg {
    var shortcutOn = ""
    var shortcutOff = ""
    var shortcutState = ""
}

func loadCfg() -> Cfg {
    var c = Cfg()
    guard let text = try? String(contentsOfFile: cfgFile, encoding: .utf8) else { return c }
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let k = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        switch k {
        case "shortcut_on": c.shortcutOn = v
        case "shortcut_off": c.shortcutOff = v
        case "shortcut_state": c.shortcutState = v
        default: break
        }
    }
    return c
}

func saveCfgKey(_ key: String, _ value: String) {
    var lines: [String] = []
    if let text = try? String(contentsOfFile: cfgFile, encoding: .utf8) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.hasPrefix(key + "=") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    if !value.isEmpty { lines.append("\(key)=\(value)") }
    try? FileManager.default.createDirectory(atPath: cfgDir, withIntermediateDirectories: true)
    try? (lines.joined(separator: "\n") + "\n").write(toFile: cfgFile, atomically: true, encoding: .utf8)
}

// ─────────────────────────── 执行外部命令 ───────────────────────────

@discardableResult
func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "") }

    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if p.isRunning { p.terminate() }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let out = String(data: data, encoding: .utf8) ?? ""
    p.waitUntilExit()
    return (p.terminationStatus, out)
}

// ─────────────────────────── 显示器读取 ───────────────────────────

func onlineDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

func uuid8(_ id: CGDirectDisplayID) -> String {
    guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "-" }
    return String((CFUUIDCreateString(nil, cf) as String).uppercased().prefix(8))
}

/// uuid8 -> (x, y, rot, 名称)
func currentRows() -> [String: (x: Int, y: Int, rot: Int, name: String)] {
    var names: [CGDirectDisplayID: String] = [:]
    for s in NSScreen.screens {
        if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            names[CGDirectDisplayID(n.uint32Value)] = s.localizedName
        }
    }
    var m: [String: (x: Int, y: Int, rot: Int, name: String)] = [:]
    for id in onlineDisplayIDs() {
        let b = CGDisplayBounds(id)
        m[uuid8(id)] = (Int(b.origin.x.rounded()), Int(b.origin.y.rounded()),
                        Int(CGDisplayRotation(id).rounded()), names[id] ?? "显示器")
    }
    return m
}

/// uuid8 -> (x, y, rot)
func snapshotRows() -> [String: (x: Int, y: Int, rot: Int)] {
    guard let t = try? String(contentsOfFile: arrangeFile, encoding: .utf8) else { return [:] }
    var m: [String: (x: Int, y: Int, rot: Int)] = [:]
    for line in t.split(separator: "\n") {
        let f = line.split(separator: "\t").map(String.init)
        guard f.count >= 4, let x = Int(f[1]), let y = Int(f[2]), let r = Int(f[3]) else { continue }
        m[f[0].uppercased()] = (x, y, r)
    }
    return m
}

struct ArrangeDiff {
    var hasSnapshot = false
    var moved: [String] = []
    var count: Int { moved.count }
}

func diffArrangement() -> ArrangeDiff {
    var d = ArrangeDiff()
    let snap = snapshotRows()
    guard !snap.isEmpty else { return d }
    d.hasSnapshot = true
    let cur = currentRows()
    for (u, s) in snap {
        guard let c = cur[u] else { continue }   // 当前没接这台，跳过
        if s.x != c.x || s.y != c.y {
            d.moved.append("\(c.name) 快照(\(s.x),\(s.y)) 现在(\(c.x),\(c.y))")
        }
    }
    d.moved.sort()
    return d
}

// ─────────────────────────── 状态 ───────────────────────────

struct State {
    var pid = ""
    var ipad = ""
    var ledger: Date?
    var shareOn: Int?
    var shortcuts = Set<String>()
    var arrange = ArrangeDiff()
    var restoreUC = false
}

final class Controller: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var cfg = loadCfg()
    var state = State()
    var menuOpen = false
    var fastBusy = false
    var slowBusy = false
    var fastTimer: Timer?
    var slowTimer: Timer?

    override init() {
        super.init()
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "通用控制")
            b.image?.isTemplate = true
            b.toolTip = "通用控制"
        }
        let m = NSMenu()
        m.delegate = self
        statusItem.menu = m

        refreshFast()
        refreshSlow()
        rebuild()

        // 后台轮询：菜单打开时纯渲染，不做任何 IO
        fastTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.refreshFast()
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshSlow()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        rebuild()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }

    /// 便宜：进程、账本时间、排列差异
    func refreshFast() {
        if fastBusy { return }
        fastBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let (_, pg) = run("/usr/bin/pgrep", ["-f", kUCPattern], timeout: 2)
            let pid = pg.split(separator: "\n").first.map(String.init) ?? ""

            var ledger: Date?
            let byhost = (home as NSString).appendingPathComponent("Library/Preferences/ByHost")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: byhost) {
                for f in files where f.hasPrefix("com.apple.universalcontrol.") && f.hasSuffix(".plist") {
                    let p = (byhost as NSString).appendingPathComponent(f)
                    if let a = try? FileManager.default.attributesOfItem(atPath: p),
                       let d = a[.modificationDate] as? Date {
                        if ledger == nil || d > ledger! { ledger = d }
                    }
                }
            }

            let diff = diffArrangement()
            let restoreUC = FileManager.default.fileExists(atPath: restoreUCFlag)

            DispatchQueue.main.async {
                self.state.pid = pid
                self.state.ledger = ledger
                self.state.arrange = diff
                self.state.restoreUC = restoreUC
                self.fastBusy = false
                if !self.menuOpen { self.rebuild() }
            }
        }
    }

    /// 慢：system_profiler / shortcuts
    func refreshSlow() {
        if slowBusy { return }
        slowBusy = true
        let cfgSnapshot = cfg

        DispatchQueue.global(qos: .utility).async {
            var ipad = ""
            let (_, bt) = run("/usr/sbin/system_profiler", ["SPBluetoothDataType"], timeout: 12)
            for line in bt.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasSuffix(":") && t.contains("iPad") { ipad = String(t.dropLast()); break }
            }

            var names = Set<String>()
            var shareOn: Int?
            if !cfgSnapshot.shortcutOn.isEmpty || !cfgSnapshot.shortcutOff.isEmpty || !cfgSnapshot.shortcutState.isEmpty {
                let (_, lst) = run("/usr/bin/shortcuts", ["list"], timeout: 10)
                for line in lst.split(separator: "\n") {
                    names.insert(line.trimmingCharacters(in: .whitespaces))
                }
            }
            if !cfgSnapshot.shortcutState.isEmpty {
                let (_, out) = run("/usr/bin/shortcuts", ["run", cfgSnapshot.shortcutState], timeout: 15)
                let v = out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["1", "true", "on", "yes", "开"].contains(v) { shareOn = 1 }
                else if ["0", "false", "off", "no", "关"].contains(v) { shareOn = 0 }
            }

            DispatchQueue.main.async {
                self.state.ipad = ipad
                self.state.shortcuts = names
                self.state.shareOn = shareOn
                self.slowBusy = false
                if !self.menuOpen { self.rebuild() }
            }
        }
    }

    // ─────────────────────── 菜单 ───────────────────────

    func rebuild() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        statusItem.button?.appearsDisabled = state.pid.isEmpty
        let running = !state.pid.isEmpty

        menu.addItem(disabled(running ? "通用控制：运行中" : "通用控制：未运行"))
        menu.addItem(disabled(state.ipad.isEmpty ? "已配对设备：未发现" : "已配对设备：\(state.ipad)"))
        if let l = state.ledger {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            menu.addItem(disabled("最近连接事件：\(f.string(from: l))"))
        }

        // ── 显示器排列 ──
        menu.addItem(.separator())
        menu.addItem(disabled("显示器排列"))

        let d = state.arrange
        if !d.hasSnapshot {
            menu.addItem(disabled("  尚未保存快照"))
        } else if d.count == 0 {
            menu.addItem(disabled("  ✓ 与快照一致"))
        } else {
            menu.addItem(disabled("  ⚠ \(d.count) 台位置与快照不同"))
            for line in d.moved.prefix(3) {
                menu.addItem(disabled("     \(line)"))
            }
        }

        let restore = NSMenuItem(title: "  还原排列", action: #selector(doRestoreArrangement), keyEquivalent: "")
        restore.target = self
        restore.isEnabled = d.hasSnapshot && FileManager.default.isExecutableFile(atPath: ucBin)
        menu.addItem(restore)

        let save = NSMenuItem(title: "  保存当前排列为快照", action: #selector(doSaveArrangement), keyEquivalent: "")
        save.target = self
        save.isEnabled = FileManager.default.isExecutableFile(atPath: ucBin)
        menu.addItem(save)

        let ucToggle = NSMenuItem(title: "  还原时一并恢复 iPad 位置（实验）",
                                  action: #selector(toggleRestoreUC), keyEquivalent: "")
        ucToggle.target = self
        ucToggle.state = state.restoreUC ? .on : .off
        menu.addItem(ucToggle)

        // ── 通用控制 ──
        menu.addItem(.separator())

        let re = NSMenuItem(title: "重新握手（重启通用控制）", action: #selector(doRestart), keyEquivalent: "r")
        re.target = self
        menu.addItem(re)

        let shareItem = NSMenuItem(title: "共享键鼠", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if !cfg.shortcutOn.isEmpty || !cfg.shortcutOff.isEmpty || !cfg.shortcutState.isEmpty {
            if let on = state.shareOn {
                sub.addItem(disabled(on == 1 ? "当前：已开启" : "当前：已关闭"))
                sub.addItem(.separator())
            }
            addShortcutItem("开启", cfg.shortcutOn, #selector(doShareOn), to: sub)
            addShortcutItem("关闭", cfg.shortcutOff, #selector(doShareOff), to: sub)
            sub.addItem(.separator())
            let rc = NSMenuItem(title: "重新配置…", action: #selector(showShortcutHelp), keyEquivalent: "")
            rc.target = self
            sub.addItem(rc)
        } else {
            let hint = NSMenuItem(title: "尚未配置快捷指令…", action: #selector(showShortcutHelp), keyEquivalent: "")
            hint.target = self
            sub.addItem(hint)
        }
        shareItem.submenu = sub
        menu.addItem(shareItem)

        let st = NSMenuItem(title: "打开通用控制设置", action: #selector(doOpenSettings), keyEquivalent: ",")
        st.target = self
        menu.addItem(st)

        menu.addItem(.separator())
        let rf = NSMenuItem(title: "刷新", action: #selector(doRefresh), keyEquivalent: "")
        rf.target = self
        menu.addItem(rf)
        let q = NSMenuItem(title: "退出", action: #selector(doQuit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func addShortcutItem(_ title: String, _ name: String, _ sel: Selector, to menu: NSMenu) {
        guard !name.isEmpty else { return }
        let exists = state.shortcuts.contains(name)
        let it = NSMenuItem(title: exists ? title : "\(title)（未找到「\(name)」）",
                            action: exists ? sel : nil, keyEquivalent: "")
        it.target = self
        it.isEnabled = exists
        menu.addItem(it)
    }

    // ─────────────────────── 动作 ───────────────────────

    @objc func doRestoreArrangement() {
        var args = ["arrange", "apply"]
        if state.restoreUC { args.append("--with-uc") }
        DispatchQueue.global().async {
            run(ucBin, args, timeout: 30)
            DispatchQueue.main.async { self.refreshFast() }
        }
    }

    @objc func doSaveArrangement() {
        var args = ["arrange", "save"]
        if state.restoreUC { args.append("--with-uc") }
        DispatchQueue.global().async {
            run(ucBin, args, timeout: 15)
            DispatchQueue.main.async { self.refreshFast() }
        }
    }

    @objc func toggleRestoreUC() {
        try? FileManager.default.createDirectory(atPath: cfgDir, withIntermediateDirectories: true)
        if state.restoreUC {
            try? FileManager.default.removeItem(atPath: restoreUCFlag)
        } else {
            FileManager.default.createFile(atPath: restoreUCFlag, contents: Data())
        }
        refreshFast()
    }

    @objc func doRestart() {
        if !state.pid.isEmpty { run("/bin/kill", ["-9", state.pid], timeout: 3) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
            let (_, pg) = run("/usr/bin/pgrep", ["-f", kUCPattern], timeout: 3)
            if pg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                run("/usr/bin/open", ["-a", kUCApp], timeout: 5)
            }
            DispatchQueue.main.async { self.refreshFast() }
        }
    }

    func runShortcut(_ name: String) {
        guard !name.isEmpty else { return }
        DispatchQueue.global().async {
            run("/usr/bin/shortcuts", ["run", name], timeout: 30)
            DispatchQueue.main.async { self.refreshSlow() }
        }
    }

    @objc func doShareOn() { runShortcut(cfg.shortcutOn) }
    @objc func doShareOff() { runShortcut(cfg.shortcutOff) }
    @objc func doRefresh() { cfg = loadCfg(); refreshFast(); refreshSlow() }
    @objc func doQuit() { NSApp.terminate(nil) }

    @objc func doOpenSettings() {
        if let u = URL(string: kSettingsURL) { NSWorkspace.shared.open(u) }
    }

    @objc func showShortcutHelp() {
        let a = NSAlert()
        a.messageText = "需要先建两个快捷指令"
        a.informativeText = """
        系统只通过 App Intent 暴露「共享键盘和鼠标」开关，没有别的调用方式。
        在「快捷指令」App 里新建两个快捷指令：

          1. 搜索「共享键盘和鼠标」，添加该动作，设为「开」，命名为：打开共享键鼠
          2. 再建一个，设为「关」，命名为：关闭共享键鼠

        然后执行：
          ~/Applications/UCMenu.app/Contents/MacOS/UCMenu shortcuts 打开共享键鼠 关闭共享键鼠
        """
        a.addButton(withTitle: "知道了")
        a.addButton(withTitle: "打开快捷指令")
        if a.runModal() == .alertSecondButtonReturn {
            if let u = URL(string: "shortcuts://") { NSWorkspace.shared.open(u) }
        }
    }
}

// ─────────────────────────── 入口 ───────────────────────────

/// 不开窗口，直接把菜单要显示的内容打出来，方便排查
func dumpState() {
    let (_, pg) = run("/usr/bin/pgrep", ["-f", kUCPattern], timeout: 3)
    let pid = pg.split(separator: "\n").first.map(String.init) ?? ""
    print("通用控制：\(pid.isEmpty ? "未运行" : "运行中 (pid \(pid))")")

    let byhost = (home as NSString).appendingPathComponent("Library/Preferences/ByHost")
    var ledger: Date?
    if let files = try? FileManager.default.contentsOfDirectory(atPath: byhost) {
        for f in files where f.hasPrefix("com.apple.universalcontrol.") && f.hasSuffix(".plist") {
            let p = (byhost as NSString).appendingPathComponent(f)
            if let a = try? FileManager.default.attributesOfItem(atPath: p),
               let d = a[.modificationDate] as? Date {
                if ledger == nil || d > ledger! { ledger = d }
            }
        }
    }
    let lf = DateFormatter(); lf.dateFormat = "MM-dd HH:mm:ss"
    print("最近连接事件：\(ledger.map { lf.string(from: $0) } ?? "无")")

    print("")
    print("显示器排列")
    let d = diffArrangement()
    if !d.hasSnapshot {
        print("  尚未保存快照（\(arrangeFile)）")
    } else if d.count == 0 {
        print("  ✓ 与快照一致")
    } else {
        print("  ⚠ \(d.count) 台位置与快照不同")
        for l in d.moved { print("     \(l)") }
    }

    // 逐台列出当前与快照，便于核对
    let cur = currentRows(), snap = snapshotRows()
    for (u, c) in cur.sorted(by: { $0.value.x < $1.value.x }) {
        let s = snap[u].map { "(\($0.x),\($0.y))" } ?? "无快照"
        print("  \(u)  \(c.name)  当前(\(c.x),\(c.y)) 快照\(s)")
    }

    print("")
    print("iPad 位置账本：\(FileManager.default.fileExists(atPath: (cfgDir as NSString).appendingPathComponent("uc-config.plist")) ? "已保存" : "未保存")")
    print("还原时一并恢复 iPad：\(FileManager.default.fileExists(atPath: restoreUCFlag) ? "开" : "关")")
    print("uc 可执行：\(FileManager.default.isExecutableFile(atPath: ucBin) ? ucBin : "找不到")")
}

@main
struct UCMenuMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let args = CommandLine.arguments
        if args.count >= 2 && args[1] == "shortcuts" {
            if args.count >= 3 { saveCfgKey("shortcut_on", args[2]) }
            if args.count >= 4 { saveCfgKey("shortcut_off", args[3]) }
            if args.count >= 5 { saveCfgKey("shortcut_state", args[4]) }
            print("已写入 \(cfgFile)")
            exit(0)
        }
        if args.count >= 2 && args[1] == "dump" {
            dumpState()
            exit(0)
        }

        let controller = Controller()
        _ = controller
        app.run()
    }
}
