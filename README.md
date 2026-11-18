# 通用控制自愈工具

Mac 和 iPad 之间共享键盘鼠标（通用控制 / Universal Control）用着用着就连不上，是 macOS 的老毛病。这个工具做两件事：**告诉你为什么坏**，以及**一键修好**。

包含两个部分：

- **`uc`** — 命令行体检与自愈（纯 shell，零依赖）
- **`UCMenu`** — 菜单栏常驻程序，把「共享键鼠」开关从设置里拎出来，断了随时点一下重连

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
  ✓ 显示器排列与快照一致

────────────────────────────────────────────────
结论：1 个风险项。处理后可执行 uc fix 重置通用控制。
```

## 安装

### 方式一：DMG（推荐，含菜单栏程序）

到 [Releases](https://github.com/MaoYo42/universal-control-fix/releases) 下载 `UniversalControlFix-<版本>.dmg`，打开后：

1. 把 `UCMenu.app` 拖进「应用程序」
2. 双击 `安装命令行工具.command`

菜单栏会出现一个键盘图标，点开就是全部功能。

> 应用是 ad-hoc 签名、未做公证，从网上下载后 Gatekeeper 会拦。
> 双击 `安装命令行工具.command` 时如果提示来自身份不明的开发者，**右键 → 打开** 即可；
> 如果提示「已损坏」，先在终端执行 `xattr -dr com.apple.quarantine "/Volumes/Universal Control Fix"` 再重试。

### 方式二：从源码

**环境要求**：macOS 12 及以上，Apple Silicon 与 Intel 都支持。`uc` 本体是纯 shell 实现，**不依赖 Xcode、Homebrew 或任何第三方工具**。

`uc arrange`（显示器排列）需要一个小程序 `ucdisplay`。安装脚本会优先用仓库里已编译好的通用二进制；找不到时才会调用 `swiftc` 现场编译。两者都不可用时，`uc arrange` 会提示功能不可用，其余命令照常工作。

```sh
git clone https://github.com/MaoYo42/universal-control-fix.git
cd universal-control-fix
./install.sh            # 装到 ~/bin/uc
./install.sh --agent    # 额外装登录自启的守候服务

./menu/build.sh --install   # 顺带装上菜单栏程序
```

`--agent` 会写入 `~/Library/LaunchAgents/local.uc.watch.plist`，由 launchd 在**每次登录时自动加载**，之后休眠唤醒会自动重置通用控制，进程意外退出也会被拉起。

想立刻生效、不等下次登录，在终端执行：

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.uc.watch.plist
```

或者直接用命令管理：

```sh
uc agent        # 看状态
uc agent on     # 装并启动
uc agent off    # 停掉并移除
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
| `uc watch [秒]` | 守候模式，**休眠唤醒后自动重置**，并监控 awdl0 / VPN 变化、显示器排列漂移 |
| `uc arrange save` | 把当前显示器排列存成快照 |
| `uc arrange apply` | 把排列贴回快照（永久写入，重连后仍保留） |
| `uc arrange save --with-uc` | 连 iPad 的逻辑位置一起存（实验） |
| `uc arrange apply --with-uc` | 连 iPad 的逻辑位置一起还原（实验） |
| `uc arrange` | 查看排列与快照的差异 |
| `uc arrange uc` | 只看 iPad 位置账本的状态 |
| `uc arrange uc edges` | 把通用控制配置里的「设备↔显示器」边表解码成人能看的 |
| `uc arrange uc diff` | 比对快照与当前边表，看位置有没有变 |
| `uc arrange auto off` | 关闭守候时的自动还原 |
| `uc log [分]` | 查看最近通用控制日志 |
| `uc agent on\|off` | 开机自动守候的 launchd 服务 |

## 菜单栏程序

`uc` 能修，但你得先知道它坏了。`UCMenu` 把状态和常用操作放进菜单栏，点开就知道：

```
通用控制：运行中
已配对设备："V" 的 iPad
最近连接事件：22:18:58
────────────────────────
显示器排列
  ⚠ 1 台位置与快照不同
     V2511 快照(-1080,-272) 现在(-1080,-350)
  还原排列
  保存当前排列为快照
  还原时一并恢复 iPad 位置（实验）
────────────────────────
重新握手（重启通用控制）    ⌘R
共享键鼠                  ▸
打开通用控制设置           ⌘,
```

要点：

- **菜单打开时不做任何 IO**，全部用后台轮询好的缓存渲染，点开即出。快查询 4 秒一次，慢查询 60 秒一次
- 排列用**快照 + 一键还原**，不做拖拽画布——画布每次弹出都要同步重建视图，实测明显卡顿
- 「共享键鼠」总开关只能经快捷指令调用（系统只通过 App Intent 暴露它），程序里点一下有帮助说明

细节见 [menu/README.md](menu/README.md)。

```sh
./menu/build.sh             # 生成 menu/build/UCMenu.app
./menu/build.sh --install   # 装到 ~/Applications 并注册登录自启
./dist/make-dmg.sh          # 打 DMG 分发包
```

## 重连后显示器位置被打乱

这是另一个独立问题，和「连不上」不是一回事：**副屏（尤其是竖屏）的位置会被系统悄悄改掉**，重连、唤醒、插拔显示器之后都可能发生。

它的成因是 macOS 在显示配置变化时会「重新居中」副屏。竖屏高度 1920 比主屏 1152 高，居中后 y 偏移就变了；偶尔甚至会被丢到主屏外面去。你可以在 `~/Library/Preferences/ByHost/com.apple.windowserver.displays.*.plist` 里看到同一台显示器历次的位置记录，Y 值在 -264 / -272 / -304 / -373 之间来回跳。

`uc arrange` 的做法是存快照、发现漂移就贴回去：

```sh
# 1. 把显示器摆成你想要的样式，然后存下来
uc arrange save

# 2. 以后被打乱了，一条命令贴回
uc arrange apply
```

存下来的快照在 `~/.config/uc/arrange.tsv`，就是几行 `UUID  x  y  旋转`。还原用的是 CoreGraphics 的 `CGConfigureDisplayOrigin` + `CGConfigureDisplayConfiguration(..., .permanently)`，会**永久写进显示配置**，不是临时改内存。

装上守候服务后（`./install.sh --agent`）连手动都不用：屏幕唤醒、显示配置变动、或者偏移稳定超过 60 秒，它都会自动贴回。

两个已知限制，用的时候会看到明确提示，不会静默失败：

- **显示器休眠时改不了**。WindowServer 会拒绝一切配置变更（错误码 1014）。`uc arrange apply` 会先自动唤醒屏幕；守候模式则跳过，等唤醒后再处理。
- **水平方向由系统接管**。副屏必须紧贴主屏边缘，X 坐标会被自动夹到 `-1080`；真正能自由调整的是 Y 偏移。

## iPad 的逻辑位置（实验）

通用控制下的 iPad **不是显示器**：`CGGetOnlineDisplayList` 永远只返回两台物理屏，它没有 framebuffer、没有 UUID、没有坐标，所以 `ucdisplay` 挪不动它。

它挂在显示器哪条边，记录在

```
~/Library/Preferences/ByHost/com.apple.universalcontrol.<硬件UUID>.plist
```

的 `Configuration` 二进制 blob 里——一个 `{vers:3, head:UUID, heap:[…]}` 的序列化结构，52 个节点，其中两个嵌套表是「设备 ↔ 显示器」的边表。**没有可读的 `defaults` 键，单个字段改不了**，只能整份导出、整份写回。

```sh
uc arrange save --with-uc     # 排列 + iPad 位置一起存
uc arrange apply --with-uc    # 排列 + iPad 位置一起还原
uc arrange uc                # 只看账本状态
uc arrange uc save|restore    # 单独存 / 单独还原
```

写回走 `defaults -currentHost export/import` 而不是直接 `cp` plist，因为写入由 `cfprefsd` 自己完成，不会被它的内存缓存覆盖回去；写完后重启 `UniversalControl.app` 让它重读配置。每次写回前会先把当前配置留一份 `.bak`。

### 边表长什么样

`Configuration` 解出来是 `{vers:3, head, heap[52], refs}`，其中 8 元列表就是边表：

```
[时间戳, 类型(0/1/3), 会话UUID, 设备UUID, 对端UUID, 显示器UUID, 边值, 边值]
```

时间戳是**开机以来的单调时钟，单位纳秒**（不是 Unix 时间，直接按秒解释会得到荒唐的 1970 年）。边值是 16 位定点数：`32767`(0x7FFF) 表示那个方向不接，`65535`(0xFFFF) 表示满，其余换算成贴边百分比。

```sh
uc arrange uc edges    # 解码出来看
uc arrange uc diff     # 快照 vs 现在，只列有变化的
```

实测：没有任何拖动时，边表的边值保持稳定，只有时间戳在刷新——所以边值确实是有意义的状态，而不是随机噪声。

**为什么标「实验」**：blob 里除了边表，还混着会话 UUID 和时间戳。写回一份旧的可能让通用控制认为有个陈旧会话，行为不一定可预期。所以 `uc arrange apply` 不会自动带上它，要显式加 `--with-uc`（或在菜单栏程序里勾上）。守候模式也**永远不碰**这个账本——自动重启通用控制只会把刚连上的连接打断。

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

