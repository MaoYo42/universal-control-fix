// ucdisplay — 读写 macOS 显示器排列关系（用于恢复被打乱的显示器位置）
//
//   ucdisplay list                    列出所有在线显示器（给人看）
//   ucdisplay list --tsv              机器可读（制表符分隔，供 shell 比对）
//   ucdisplay set <uuid> <x> <y> [--permanent]   按 UUID 设置显示器原点
//   ucdisplay move <x> <y> <W>x<H> [--permanent] 按像素尺寸设置（兼容旧用法）
//
// --permanent 会把排列写进显示配置（重启、重连后仍然保留）；
// 不加则只对当前会话生效（WindowServer 重配后失效）。
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
    return CFUUIDCreateString(nil, cf) as String
}

func origin(_ id: CGDirectDisplayID) -> (Int, Int) {
    let b = CGDisplayBounds(id)
    return (Int(b.origin.x.rounded()), Int(b.origin.y.rounded()))
}

func rotation(_ id: CGDirectDisplayID) -> Int {
    Int(CGDisplayRotation(id).rounded())
}

func describe(_ id: CGDirectDisplayID) -> String {
    let pw = CGDisplayPixelsWide(id)
    let ph = CGDisplayPixelsHigh(id)
    let b = CGDisplayBounds(id)
    let main = CGDisplayIsMain(id) != 0
    let rot = rotation(id)
    let uuid = uuidString(id)
    return "id=\(id) uuid=\(uuid.prefix(8)) px=\(pw)x\(ph) pt=\(Int(b.width))x\(Int(b.height)) origin=(\(Int(b.origin.x)),\(Int(b.origin.y))) rot=\(rot)\(main ? " MAIN" : "")"
}

func tsvLine(_ id: CGDirectDisplayID) -> String {
    let pw = CGDisplayPixelsWide(id)
    let ph = CGDisplayPixelsHigh(id)
    let (x, y) = origin(id)
    let uuid = String(uuidString(id).prefix(8))
    let main = CGDisplayIsMain(id) != 0 ? 1 : 0
    return "\(uuid)\t\(x)\t\(y)\t\(rotation(id))\t\(pw)\t\(ph)\t\(main)"
}

func cmdList(tsv: Bool) {
    let ids = onlineDisplays()
    if tsv {
        // 固定顺序，方便 diff / 逐行比对
        for id in ids.sorted(by: { uuidString($0) < uuidString($1) }) {
            print(tsvLine(id))
        }
        return
    }
    print("在线显示器 \(ids.count) 台")
    for id in ids.sorted(by: { CGDisplayIsMain($0) != 0 && CGDisplayIsMain($1) == 0 }) {
        print("  " + describe(id))
    }
}

/// 真正下发位置。permanent=true 时写进显示配置，重连/重启后仍保留。
func applyOrigin(_ id: CGDirectDisplayID, _ x: Int, _ y: Int, permanent: Bool) -> Int32 {
    // 显示器休眠时 WindowServer 会拒绝一切配置变更（CGError 1014），
    // 这里提前拦下，给出人话提示。
    if CGDisplayIsAsleep(id) != 0 {
        FileHandle.standardError.write("显示器正在休眠，系统会拒绝调整排列（错误码 1014）\n".data(using: .utf8)!)
        FileHandle.standardError.write("唤醒屏幕后再试，或先执行：caffeinate -u -t 2\n".data(using: .utf8)!)
        return 9
    }
    let before = origin(id)
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else {
        FileHandle.standardError.write("无法开始显示配置\n".data(using: .utf8)!)
        return 5
    }
    let r = CGConfigureDisplayOrigin(c, id, Int32(x), Int32(y))
    if r != .success {
        CGCompleteDisplayConfiguration(c, .forSession)
        FileHandle.standardError.write("设置位置失败（错误码 \(r.rawValue)）\n".data(using: .utf8)!)
        return 6
    }
    let opt: CGConfigureOption = permanent ? .permanently : .forSession
    let done = CGCompleteDisplayConfiguration(c, opt)
    guard done == .success else {
        FileHandle.standardError.write("提交配置失败（错误码 \(done.rawValue)）\n".data(using: .utf8)!)
        return 7
    }
    Thread.sleep(forTimeInterval: 0.35)
    let after = origin(id)
    let uuid = String(uuidString(id).prefix(8))
    print("\(uuid)  位置 (\(before.0),\(before.1)) → (\(after.0),\(after.1))\(permanent ? "  [已写入]" : "")")
    if after.0 != x || after.1 != y {
        FileHandle.standardError.write("警告：位置未完全生效，系统可能覆盖了该坐标\n".data(using: .utf8)!)
        return 8
    }
    return 0
}

func find(_ key: String) -> CGDirectDisplayID? {
    let k = key.uppercased()
    let ids = onlineDisplays()
    // 支持完整 UUID 或前 8 位
    for id in ids where uuidString(id).uppercased().hasPrefix(k) { return id }
    return nil
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("用法：ucdisplay list [--tsv] | set <uuid> <x> <y> [--permanent] | move <x> <y> <W>x<H> [--permanent]")
    exit(1)
}

let permanent = args.contains("--permanent")

switch cmd {
case "list":
    cmdList(tsv: args.contains("--tsv"))

case "asleep":
    // 供 shell 判断：任一显示器休眠就输出 yes
    let any = onlineDisplays().contains { CGDisplayIsAsleep($0) != 0 }
    print(any ? "yes" : "no")

case "set":
    guard args.count >= 4, let x = Int(args[2]), let y = Int(args[3]) else {
        FileHandle.standardError.write("用法：ucdisplay set <uuid> <x> <y> [--permanent]\n".data(using: .utf8)!)
        exit(2)
    }
    guard let id = find(args[1]) else {
        FileHandle.standardError.write("没有找到 UUID 以 \(args[1]) 开头的在线显示器\n".data(using: .utf8)!)
        exit(3)
    }
    if CGDisplayIsMain(id) != 0 && (x != 0 || y != 0) {
        // 主显示器原点恒为 (0,0)，改它没有意义
        print("\(String(uuidString(id).prefix(8)))  主显示器位置固定为 (0,0)，已跳过")
        exit(0)
    }
    exit(applyOrigin(id, x, y, permanent: permanent))

case "move":
    guard args.count >= 4, let x = Int(args[1]), let y = Int(args[2]) else {
        FileHandle.standardError.write("用法：ucdisplay move <x> <y> <W>x<H> [--permanent]\n".data(using: .utf8)!)
        exit(2)
    }
    let parts = args[3].lowercased().split(separator: "x")
    guard parts.count == 2, let tw = Int(parts[0]), let th = Int(parts[1]) else {
        FileHandle.standardError.write("分辨率格式应为 1080x1920\n".data(using: .utf8)!)
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
    exit(applyOrigin(matches[0], x, y, permanent: permanent))

default:
    FileHandle.standardError.write("未知命令：\(cmd)\n".data(using: .utf8)!)
    exit(1)
}
