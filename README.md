# 通用控制自愈工具

Mac 和 iPad 之间共享键盘鼠标（通用控制 / Universal Control）用着用着就连不上，是 macOS 的老毛病。这个工具做两件事：**告诉你为什么坏**，以及**一键修好**。

包含两个部分：

- **`uc`** — 命令行体检与自愈（纯 shell，零依赖）
- **`UCMenu`** — 菜单栏常驻程序，把「共享键鼠」开关从设置里拎出来，**左键点一下图标就直接重连**

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
| `uc arrange` | 查看排列与快照的差异 |
| `uc arrange auto off` | 关闭守候时的自动还原 |
| `uc ipad` | iPad 的逻辑位置现在被系统放在哪（只读） |
| `uc arrange uc edges` | 把通用控制配置里的「设备↔显示器」边表解码成人能看的（只读） |
| `uc log [分]` | 查看最近通用控制日志 |
| `uc agent on\|off` | 开机自动守候的 launchd 服务 |
| `uc mouse` | 鼠标在 iPad 上滚轮反向 / 不顺的排查清单 |

## 菜单栏程序

`uc` 能修，但你得先知道它坏了。`UCMenu` 把状态和常用操作放进菜单栏，**左键单击图标就直接重新握手**（右键或 `⌥` 点击才展开下面这个菜单）：

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
  iPad 位置（只读）…
────────────────────────
重新握手（重启通用控制）    ⌘R
单击图标直接重连           ✓
  右键或 ⌥ 点击图标，随时打开这个菜单
共享键鼠                  ▸
鼠标手感排查…
打开通用控制设置           ⌘,
```

要点：

- **左键＝重连，右键＝菜单**。这个程序的使用场景就是「断了才点」，不该还要两步。点下去图标立刻变成同步箭头，重连完成恢复；期间再点无效，不会连着杀进程。菜单里可以取消勾选改回「单击只弹菜单」
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

## iPad 的逻辑位置

通用控制下的 iPad **不是显示器**：`CGGetOnlineDisplayList` 永远只返回物理屏，它没有 framebuffer、没有 displayID、没有可写的坐标。

**结论：这个位置只能人手动拖，工具改不了。** 下面写清楚为什么，以及曾经踩过的坑。

### 位置到底存在哪

在 WindowServer 的显示配置里：

```
~/Library/Preferences/ByHost/com.apple.windowserver.displays.<硬件UUID>.plist
  → DisplaySets.Configs[].DisplayConfig[]
```

iPad 会作为一条带 `OriginX` / `OriginY` 的记录出现（本机是 `26EE7C3A-…`），和物理屏并列。但它没有 `CGDirectDisplayID`，`CGConfigureDisplayOrigin` 碰不到；直接改 plist 又要重启 WindowServer，等于注销重登。所以没有可行的程序化改法。

```sh
uc ipad    # 读出来告诉你它现在在哪，以及历史上常被放到哪
```

典型输出：

```
  当前排列里 iPad 在 (0, 0)   ← 与主屏完全重叠
     这个位置就是它跟着主屏一起动的原因，鼠标在主屏上会直接穿过去。

  历史上非物理屏条目出现的位置（含 iPad 和其他已断开的显示器）：
    (     0,      0)  10 次  ⚠ 和主屏重叠
    (     0,  -1080)   5 次  主屏上方
    (  1920,      0)   4 次  主屏右侧
    (     0,   1080)   3 次  主屏下方
```

`(0,0)` 是通用控制的**未初始化默认值**——和主屏坐标完全相同。它一出现，表现就是「iPad 跟着主屏动，鼠标在主屏上会穿过去」。

### 怎么改

**系统设置 → 显示器 → 排列**，iPad 连着时会作为第三个方块出现，直接拖。

### 曾经写过的「一键还原」为什么删了

1.3.0 到 1.3.2 之间有过一套 `--with-uc`：把通用控制配置（`com.apple.universalcontrol.<uuid>.plist` 里的 `Configuration` blob）整份备份、整份写回，指望能还原 iPad 位置。

**实测证明它没用而且有害，已经整段删除：**

- **边表 12 小时零变化**。期间通用控制断连重连 4 次，边值一个都没动。那张「设备↔显示器」边表记录的是**连接事件历史**，不是位置配置。
- **写回必须重启 `UniversalControl.app`** 才会被重读。而一重启，iPad 断连重连，位置被重置回 `(0,0)`。等于什么都没改，反而把好位置弄没了。

现在只保留只读解码（`uc arrange uc edges`），不写任何东西。`Configuration` 的结构和解码细节记在 [AUDIT.md](AUDIT.md) 里，万一以后要重新研究有据可查。

## 鼠标在 iPad 上滚轮反向 / 不顺

**Mac 这边怎么调都没用。** 通用控制只负责把指针和滚动事件转发过去，怎么解释这些事件是 iPadOS 的事。要调的是 iPad。

```sh
uc mouse    # 打印当前 Mac 侧的值 + iPad 侧该怎么设
```

菜单栏程序里也有「鼠标手感排查…」，内容一样，可以一键复制成文本。

### 苹果把鼠标设置散在三个地方

这是公认的痛点，也是最容易漏项的原因。按顺序走一遍：

#### ① 设置 → 通用 → 触控板与鼠标

只有三项，其中有用的是**自然滚动**。

它和 Mac 的 `com.apple.swipescrolldirection` 是**两个完全独立的开关**，在 Mac 上改不影响 iPad。两边不一致就会反向。

> 实测：Mac 默认是开着自然滚动的（该键不存在 = 开启），这种情况下 **iPad 要关掉**「自然滚动」，方向才一致。

#### ② 设置 → 无障碍（旧版叫「辅助功能」）→ 指针控制

| 选项 | 怎么设 | 为什么 |
|---|---|---|
| **滚动速度** | 拉到最右 | **最容易被漏掉的一项。默认只有滑条的 1/3**，滚一格几乎不动，手感就是「不顺」 |
| 跟踪速度 | 拉到最快 | 指针移动快慢 |
| 指针加速度 | 关掉 | 开着时滚轮会被叠一层非线性放大，表现出来就是「一顿一顿」 |
| 指针动画 | 关掉 | 否则光标会被 App 图标「吸」进去，移出来还得找 |

「滚动速度」和「跟踪速度」是两个滑块，管的事情完全不同——只调后者不会让滚动变快。

#### ③ 设置 → 无障碍 → 触控 → 辅助触控 → 指针设备

- **追踪灵敏度** — ② 调完还嫌慢的话，这里能再快一档
- **设备 → 点开你的鼠标 → 自定义按钮** — 可以绑截屏、通知中心、控制中心、快捷指令

#### ④ 还是不顺

换触控板。这不是敷衍——**滚轮是离散步进，iPadOS 对滚轮不做插值**，只有触控板才有惯性滚动和亚像素精度。通用控制转发的是手势，iPadOS 会按原生触控板处理，手感立刻正常。

另外，如果目的只是「把 iPad 当 Mac 的第二块屏」，用**随航（Sidecar）**比通用控制顺得多：iPad 会变成一个真正的显示器，滚动由 macOS 自己渲染。代价是 iPad 上显示的是 Mac 桌面，不能同时用 iPad 自己的 App。

### 有没有 iPad 端的软件能改这个

**没有，而且不是没人做，是做不到。**

iPadOS 不向第三方 App 开放系统级输入拦截——没有 macOS 上 `CGEventTap` 那种东西。第三方 App 只能处理投递到自己窗口内的触摸/指针事件，改不了全系统的鼠标行为。

搜到的结果分两类，都不是要的：

- **反向的**：Remouse、Tracepad、Mobile Mouse 这类，把 iPad 变成 Mac 的鼠标/触控板
- **越狱插件**：理论上能改（GitHub 上有 `custom-mouse-dpi-driver` 这类 HID 过滤驱动），但 iPad Air 7 跑 iPadOS 26+ 目前没有可用越狱

所以能动的只有上面那三个设置页。

### Mac 端的第三方滚动工具对通用控制有用吗

同样**没有验证过的成品**：

| 工具 | 原理 | 对通用控制 |
|---|---|---|
| [Mos](https://github.com/Caldis/Mos) | 全局 CGEventTap，拦截重写滚动事件，可调最短步长/速度增益 | README 未提及 |
| Mac Mouse Fix | IOKit HID 事件重构 | 未提及 |
| [Scroll Reverser](https://pilotmoon.com/scrollreverser) | 只翻转方向 | 未提及 |

它们改的都是 **Mac 本地**的 CGEvent 流，而通用控制把事件转发给 iPad 走的是另一条路。装上滚两下就知道了，别指望。

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

## 开发

- [AUDIT.md](AUDIT.md) — 一次系统性审计的记录。重点不是列了哪些 bug，
  而是**怎么找出来的**和**怎么验证修好了**，以及一份回归清单。
  改这块代码前建议先看它，尤其是「假成功」那一节。
- [menu/README.md](menu/README.md) — 菜单栏程序的设计与构建细节

## 许可

MIT。随便改、随便传。

