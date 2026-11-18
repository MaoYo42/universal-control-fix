# uc — macOS 通用控制体检与自愈

Mac 和 iPad 之间共享键盘鼠标（通用控制 / Universal Control）用着用着就连不上，是 macOS 的老毛病。这个工具做两件事：**告诉你为什么坏**，以及**一条命令修好**。

```console
$ uc
通用控制体检  Mac16,10 / macOS 27.2.1
────────────────────────────────────────────────
基础条件
  ✓ Wi-Fi        5GHz · 信道 149 (80MHz) · -34dBm · 585Mbps
  ✓ 蓝牙         已开启
  ✓ 点对点链路   awdl0 正常
  ✓ 通用控制     运行中 · pid 66386 · 已运行 12 分钟
  ✓ 已配对 iPad  "V"的 iPad

风险项
  ⚠ 蓝牙同时连接 3 个设备，会挤占通用控制的握手链路
      耳机   Mijia Glasses Lite            ← 音频流最占带宽，最该断
      鼠标   SPK7858
      手柄   Xbox Wireless Controller
      → 不用时断开耳机和手柄，能立刻改善

────────────────────────────────────────────────
结论：1 个风险项。处理后可执行 uc fix 重置通用控制。
```

## 安装

**环境要求**：macOS（通用控制本身需 macOS 12 及以上）。纯 shell 实现，**不依赖 Xcode、Homebrew 或任何第三方工具**，也不需要装命令行开发者工具。

```sh
./install.sh            # 装到 ~/bin/uc
./install.sh --agent    # 额外装登录自启的守候服务
```

`--agent` 会写入 `~/Library/LaunchAgents/local.uc.watch.plist`，由 launchd 在**每次登录时自动加载**，之后休眠唤醒会自动重置通用控制，进程意外退出也会被拉起。

想立刻生效、不等下次登录，在终端执行：

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.uc.watch.plist
```

查看守候日志（只有事件发生时才写，不会膨胀）：

```sh
tail -f ~/Library/Logs/uc-watch.log
```

临时停止 / 彻底移除：

```sh
launchctl bootout gui/$(id -u)/local.uc.watch   # 本次登录内停止
./install.sh --uninstall                        # 删除命令与服务
```

## 用法

| 命令 | 作用 |
|---|---|
| `uc` | 体检报告，列出所有影响通用控制的环节 |
| `uc fix` | 重置通用控制，约 1 秒 |
| `uc watch [秒]` | 守候模式，**休眠唤醒后自动重置**，并监控 awdl0 / VPN 变化 |
| `uc log [分]` | 查看最近通用控制日志 |

## 它在查什么

通用控制能跑起来，依赖四个东西同时正常。任何一个断了，症状都是「光标跨不过去」，但原因完全不同：

1. **Wi-Fi** — 数据走 Wi-Fi 的点对点链路，不是蓝牙。2.4GHz 会和蓝牙抢频段。
2. **蓝牙** — 只负责「发现附近设备」的握手。连一堆蓝牙设备（耳机、手柄、鼠标）会挤占这条链路，这是最常见的隐形杀手。
3. **awdl0** — Apple 的 AWDL 点对点接口。VPN（尤其全隧道）、睡眠唤醒后没恢复，都会让它挂掉。它一挂，通用控制、随航、AirDrop、接力**全部一起失效**。
4. **UniversalControl 进程** — 偶尔会卡死。它本身有系统托管，杀掉后 1 秒内自动拉起，所以重启是安全的。

`uc` 就是把这四项逐个查一遍，有问题的标出来并说明怎么处理。

## 为什么不做「点系统设置」那种方案

GitHub 上唯一的同类项目 `nathanbirrell/macos-restart-universal-control` 用的是 AppleScript **模拟点击系统设置里的复选框**。它依赖具体的 UI 元素层级（`checkbox ... of group 2 of scroll area 1 of ...`），每个 macOS 大版本都可能失效。

这个工具只用系统真实机制：读 `system_profiler` / `ifconfig` / `scutil`，写进程信号。不碰任何界面，macOS 升级也不会坏。

## 进阶：关掉边缘穿越

如果你遇到的是「光标自己乱跳过去」而不是「连不上」，可以关掉边缘穿越，改成手动连接：

```sh
defaults -currentHost write com.apple.universalcontrol DisableMagicEdges -bool true
uc fix
```

之后要在「显示器」菜单里手动选「链接键盘和鼠标」才会连接。想恢复：

```sh
defaults -currentHost delete com.apple.universalcontrol DisableMagicEdges
uc fix
```

## 卸载

```sh
./install.sh --uninstall
```

## 其他方案（不适用本机的，供参考）

- **硬件桥**：`lockekk/dshare-hid`（295★）用 ESP32-C3（约 20 元）把键鼠转成蓝牙 HID 发给 iPad，完全绕开通用控制。iPadOS 不允许后台应用拦截系统级 HID 事件，所以纯软件方案在 iPad 上不存在。
- **随航**：iPad 当副屏，Mac 键鼠直接操作 iPad App。稳定性通常比通用控制好，但没有「两台独立设备」的体验。
- **opendisplay**（6.4k★）：开源版随航。

## 许可

MIT。随便改、随便传。

