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

    // 超时后先 SIGTERM，给 1 秒收尾；还不退就 SIGKILL。
    // 只发 SIGTERM 就 waitUntilExit 是有风险的：进程忽略信号时会永久挂住，
    // 而调用方（fastBusy/slowBusy 的守卫）会被永久卡在 busy 状态。
    if p.isRunning {
        p.terminate()
        let grace = Date().addingTimeInterval(1.0)
        while p.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

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
    var shareBusy = false
    var fastTimer: Timer?
    var slowTimer: Timer?
    /// 上一次渲染对应的状态指纹，用来避免每 4 秒无意义地重建整个菜单
    var lastSig = ""

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
        refreshShareState()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        // 展开期间后台刷新不重建菜单，这里补一次（没变化会自己跳过）
        rebuild()
    }

    /// 便宜：进程、账本时间、排列差异
    ///
    /// 注意：NSScreen 不是线程安全的，必须在主线程取。所以
    /// diffArrangement()（内部用 NSScreen.screens 拿显示器名字）
    /// 放在回到主线程之后算，后台只做真正会阻塞的进程调用和文件 stat。
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

            let restoreUC = FileManager.default.fileExists(atPath: restoreUCFlag)

            DispatchQueue.main.async {
                self.state.pid = pid
                self.state.ledger = ledger
                self.state.arrange = diffArrangement()   // 主线程，NSScreen 安全
                self.state.restoreUC = restoreUC
                self.fastBusy = false
                if !self.menuOpen { self.rebuild() }
            }
        }
    }

    /// 慢：system_profiler / shortcuts 列表
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
            if !cfgSnapshot.shortcutOn.isEmpty || !cfgSnapshot.shortcutOff.isEmpty || !cfgSnapshot.shortcutState.isEmpty {
                let (_, lst) = run("/usr/bin/shortcuts", ["list"], timeout: 10)
                for line in lst.split(separator: "\n") {
                    names.insert(line.trimmingCharacters(in: .whitespaces))
                }
            }

            DispatchQueue.main.async {
                self.state.ipad = ipad
                self.state.shortcuts = names
                self.slowBusy = false
                if !self.menuOpen { self.rebuild() }
            }
        }
    }

    /// 共享键鼠的当前状态
    ///
    /// 只能靠「跑一个快捷指令、读它的输出」来查，而 `shortcuts run` 是有副作用的
    /// ——可能弹横幅、可能抢焦点。所以不放定时器里，改成打开菜单时才查一次。
    /// 菜单先用缓存值渲染，查到后如果变了再刷一次。
    func refreshShareState() {
        let name = cfg.shortcutState
        guard !name.isEmpty, state.shortcuts.contains(name) else { return }
        if shareBusy { return }
        shareBusy = true
        DispatchQueue.global(qos: .utility).async {
            let (_, out) = run("/usr/bin/shortcuts", ["run", name], timeout: 15)
            let v = out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var on: Int?
            if ["1", "true", "on", "yes", "开"].contains(v) { on = 1 }
            else if ["0", "false", "off", "no", "关"].contains(v) { on = 0 }
            DispatchQueue.main.async {
                self.state.shareOn = on
                self.shareBusy = false
                if !self.menuOpen { self.rebuild() }
            }
        }
    }

    // ─────────────────────── 菜单 ───────────────────────

    /// 把影响菜单外观的所有状态压成一个字符串。
    /// 每 4 秒无条件 removeAllItems 重建十几个菜单项，虽然不泄漏，
    /// 但会白白制造对象和两次 stat 系统调用，而且会让菜单有细微抖动。
    func stateSignature() -> String {
        var s = "\(state.pid)|\(state.ipad)|\(state.shareOn.map(String.init) ?? "-")"
        s += "|\(state.restoreUC ? 1 : 0)|\(state.shortcuts.count)"
        s += "|\(state.ledger?.timeIntervalSince1970 ?? 0)"
        s += "|\(state.arrange.hasSnapshot ? 1 : 0)"
        s += "|" + state.arrange.moved.joined(separator: ";")
        s += "|\(cfg.shortcutOn)|\(cfg.shortcutOff)|\(cfg.shortcutState)"
        s += "|\(FileManager.default.isExecutableFile(atPath: ucBin) ? 1 : 0)"
        return s
    }

    func rebuild(force: Bool = false) {
        guard let menu = statusItem.menu else { return }
        let sig = stateSignature()
        if !force && sig == lastSig { return }
        lastSig = sig

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

        // 这个开关同时影响「保存」和「还原」——没有 iPad 位置快照就无从还原，
        // 所以标题必须写清楚，不能只说「还原时」
        let ucToggle = NSMenuItem(title: "  iPad 位置：保存与还原一并处理（实验）",
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

        let mouse = NSMenuItem(title: "鼠标手感排查…", action: #selector(showMouseHelp), keyEquivalent: "")
        mouse.target = self
        menu.addItem(mouse)

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
        // 整条链路都放后台：run() 会阻塞调用线程，放在主线程会让菜单卡住
        let pid = state.pid
        DispatchQueue.global(qos: .userInitiated).async {
            if !pid.isEmpty { run("/bin/kill", ["-9", pid], timeout: 3) }
            Thread.sleep(forTimeInterval: 1.2)
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
            DispatchQueue.main.async { self.refreshShareState() }
        }
    }

    @objc func doShareOn() { runShortcut(cfg.shortcutOn) }
    @objc func doShareOff() { runShortcut(cfg.shortcutOff) }
    @objc func doRefresh() {
        cfg = loadCfg()
        refreshFast()
        refreshSlow()
        refreshShareState()
    }
    @objc func doQuit() { NSApp.terminate(nil) }

    /// 通用控制下，鼠标在 iPad 上的手感不由 Mac 决定。
    /// Mac 只负责转发事件，怎么解释是 iPadOS 的事 —— 所以得去 iPad 上调。
    /// 苹果把这几项散在三个地方，按顺序走一遍。
    @objc func showMouseHelp() {
        let (_, out) = run("/usr/bin/defaults", ["read", "-g", "com.apple.swipescrolldirection"], timeout: 3)
        let v = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let macNatural: String
        if v.isEmpty { macNatural = "开启（默认）" }
        else { macNatural = (v == "1") ? "开启" : "关闭" }

        let a = NSAlert()
        a.messageText = "iPad 上的鼠标手感由 iPad 自己决定"
        a.informativeText = """
        Mac 只负责把指针和滚动事件转发过去，改 Mac 这边的设置不影响 iPad。
        当前 Mac 的「自然滚动」：\(macNatural)

        苹果把鼠标设置散在三个地方，按这个顺序走一遍：

        ① 设置 → 通用 → 触控板与鼠标
           自然滚动：和上面 Mac 的值保持一致，不一致就会反向。
           实测 Mac 开着自然滚动时，iPad 要关掉才是同一方向。

        ② 设置 → 无障碍（旧版叫「辅助功能」）→ 指针控制
           · 滚动速度 ← 最容易漏的一项，默认只有滑条的 1/3，
             拉到最右边，滚一格才真的走得动
           · 跟踪速度：拉到最快
           · 指针加速度：关掉，开着时滚轮会一顿一顿
           · 指针动画：关掉，光标就不会被 App 图标吸进去

        ③ 设置 → 无障碍 → 触控 → 辅助触控 → 指针设备
           · 追踪灵敏度：② 调完还嫌慢的话，这里能再快一档
           · 设备 → 点开你的鼠标 → 自定义按钮
             （可绑截屏、通知中心、控制中心、快捷指令）

        ④ 还是不顺就换触控板
           滚轮是离散步进，iPadOS 不做插值；
           触控板走的是手势，iPadOS 按原生方式处理。

        App Store 上没有能改这件事的软件：iPadOS 不开放系统级输入拦截，
        第三方 App 只能处理自己窗口里的输入，改不了全系统的鼠标行为。
        """
        a.addButton(withTitle: "知道了")
        a.addButton(withTitle: "复制成文本")
        if a.runModal() == .alertSecondButtonReturn {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(a.informativeText, forType: .string)
        }
    }

    @objc func doOpenSettings() {        if let u = URL(string: kSettingsURL) { NSWorkspace.shared.open(u) }
    }

    @objc func showShortcutHelp() {        let a = NSAlert()
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
