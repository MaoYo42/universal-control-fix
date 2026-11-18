// ucdisplay — 列出/移动 macOS 显示器位置（用于恢复通用控制 iPad 的排列关系）
//
//   ucdisplay list              列出所有在线显示器
//   ucdisplay move <x> <y> <W>x<H>   把指定分辨率的显示器移到 (x, y)
//
// 编译：swiftc -O -o ucdisplay ucdisplay.swift -framework CoreGraphics -framework AppKit

import Foundation
import CoreGraphics
import AppKit

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

func uuidString(_ id: CGDirectDisplayID) -> String {
    guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "-" }
    let s = CFUUIDCreateString(nil, cf) as String
    return s
}

func describe(_ id: CGDirectDisplayID) -> String {
    let pw = CGDisplayPixelsWide(id)
    let ph = CGDisplayPixelsHigh(id)
    let b = CGDisplayBounds(id)
    let main = CGDisplayIsMain(id) != 0
    let rot = Int(CGDisplayRotation(id).rounded())
    let uuid = uuidString(id)
    return "id=\(id) uuid=\(uuid.prefix(8)) px=\(pw)x\(ph) pt=\(Int(b.width))x\(Int(b.height)) origin=(\(Int(b.origin.x)),\(Int(b.origin.y))) rot=\(rot)\(main ? " MAIN" : "")"
}

func cmdList() {
    let ids = onlineDisplays()
    print("在线显示器 \(ids.count) 台")
    for id in ids {
        print("  " + describe(id))
    }
}

func cmdMove(_ x: Int, _ y: Int, _ target: String) {
    let parts = target.lowercased().split(separator: "x")
    guard parts.count == 2, let tw = Int(parts[0]), let th = Int(parts[1]) else {
        FileHandle.standardError.write("分辨率格式应为 2360x1640\n".data(using: .utf8)!)
        exit(2)
    }
    let matches = onlineDisplays().filter {
        Int(CGDisplayPixelsWide($0)) == tw && Int(CGDisplayPixelsHigh($0)) == th
    }
    if matches.isEmpty {
        FileHandle.standardError.write("没有找到 \(tw)x\(th) 的在线显示器\n".data(using: .utf8)!)
        exit(3)
    }
    if matches.count > 1 {
        FileHandle.standardError.write("匹配到 \(matches.count) 台，无法确定目标\n".data(using: .utf8)!)
        exit(4)
    }
    let id = matches[0]
    let before = CGDisplayBounds(id)
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else {
        FileHandle.standardError.write("无法开始显示配置\n".data(using: .utf8)!)
        exit(5)
    }
    let r = CGConfigureDisplayOrigin(c, id, Int32(x), Int32(y))
    if r != .success {
        CGCompleteDisplayConfiguration(c, .forSession)
        FileHandle.standardError.write("设置位置失败（错误码 \(r.rawValue)）\n".data(using: .utf8)!)
        exit(6)
    }
    guard CGCompleteDisplayConfiguration(c, .forSession) == .success else {
        FileHandle.standardError.write("提交配置失败\n".data(using: .utf8)!)
        exit(7)
    }
    // 稍等再读回，确认真的生效
    Thread.sleep(forTimeInterval: 0.4)
    let after = CGDisplayBounds(id)
    print("\(tw)x\(th)  位置 (\(Int(before.origin.x)),\(Int(before.origin.y))) → (\(Int(after.origin.x)),\(Int(after.origin.y)))")
    if Int(after.origin.x) != x || Int(after.origin.y) != y {
        FileHandle.standardError.write("警告：设置未生效，系统可能覆盖了该位置\n".data(using: .utf8)!)
        exit(8)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("用法：ucdisplay list | ucdisplay move <x> <y> <W>x<H>")
    exit(1)
}
switch cmd {
case "list":
    cmdList()
case "move":
    guard args.count >= 4, let x = Int(args[1]), let y = Int(args[2]) else {
        FileHandle.standardError.write("用法：ucdisplay move <x> <y> <W>x<H>\n".data(using: .utf8)!)
        exit(2)
    }
    cmdMove(x, y, args[3])
default:
    FileHandle.standardError.write("未知命令：\(cmd)\n".data(using: .utf8)!)
    exit(1)
}
