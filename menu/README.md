# UCMenu — 通用控制的菜单栏开关

macOS 把「连接键盘和鼠标至 …」这个入口藏在「显示器」设置的下拉里，还时隐时现。断了想重连，得一路翻进去找。

这是个菜单栏常驻小程序，把它拎出来。

```
通用控制：运行中
已配对设备："V" 的 iPad
最近连接事件：21:53:29
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
────────────────────────
刷新
退出                      ⌘Q
```

## 构建

只需要 Command Line Tools，**不需要 Xcode**。

```sh
./build.sh              # 生成 build/UCMenu.app
./build.sh --install    # 装到 ~/Applications 并注册登录自启
./build.sh --uninstall  # 移除
```

产物是**通用二进制**（arm64 + x86_64），图标用 SF Symbol 的 `keyboard` 现场画出来再转 `.icns`，不需要额外设计资源。

两个构建细节：

- 必须加 `-parse-as-library`。文件级 `let` 常量在单文件编译时会被判成 top-level code，跟 `@main` 冲突
- x86_64 切片的部署目标要定在 **14.0**。CLT 的 `libswiftCompatibility56.a` 只带 arm64 切片，目标定在 12.0 会链接失败；arm64 切片仍是 12.0，所以旧系统上的 Apple Silicon 机器不受影响

## 功能

**单击图标＝立刻重新握手** — 这个程序的使用场景很单一：断连了才去点它。所以左键点图标直接重启 `UniversalControl.app`，不用先弹菜单再点一项。右键、`⌥` 点击、`⌃` 点击仍然打开完整菜单。

点下去图标会立刻换成同步箭头并变暗，重连完成后恢复，鼠标悬停能看到「最近重连 HH:mm:ss」。重连期间再点是无效的，不会连着杀进程。

想改回「单击只弹菜单」，把菜单里的「单击图标直接重连」取消勾选即可（写进 `~/.config/uc/menu.conf` 的 `click_action=menu`）。

实现上有个坑：`statusItem.menu` 一旦赋值，AppKit 就把点击拿去掉菜单了，`button.action` 永远不触发。所以菜单是自己持有的，只在弹菜单的那一刻临时挂上去、`performClick` 之后再摘掉。

```sh
pkill -f "UCMenu.app/Contents/MacOS/UCMenu"    # 自检前必须先退出，见下
~/Applications/UCMenu.app/Contents/MacOS/UCMenu selftest
# 点击分支断言：全部通过（5 条）
# 菜单展开中：menuOpen=true items=19
# 菜单已关闭：menuOpen=false 本次弹出=是
```

自检会断言左右键分支，并真的弹一次菜单再自己关掉。**必须先退出正在运行的实例**：同一 bundle id 的第二个实例并存时 `performClick` 弹不出菜单，自检会误报成「点了没反应」，排查方向就全错了。

**重新握手** — 直接重启 `UniversalControl.app`。它由系统托管，杀掉后 1 秒内自动拉起，实测安全。这是「连不上」时最有效的一招。

**打开通用控制设置** — 用系统自带的深链，直接落到「显示器 → 通用控制」区块，不用自己翻：

```
x-apple.systempreferences:com.apple.Displays-Settings.extension?sidecarSection
```

**排列还原：快照 + 一键贴回** — 不做拖拽画布，只做两件事：

1. 你在系统原生「显示器 → 排列」里把位置摆对（这是唯一可信的输入源，所见即所得）
2. 菜单里点「保存当前排列为快照」

之后排列只要被 macOS 重新居中、漂移、或者显示器热插拔后乱掉，菜单顶部会直接显示差在哪：

```
⚠ 1 台位置与快照不同
   V2511 快照(-1080,-272) 现在(-1080,-350)
```

点一下「还原排列」就贴回去，永久写入显示配置。

为什么不做拖拽画布：试过一版，每次打开菜单都要同步重建自定义视图，实测明显卡顿，还不如不做。按键式的好处是零渲染开销、状态一眼可见、不会误拖。

**iPad 位置（只读）** — 跑 `uc ipad`，告诉你系统把 iPad 放在哪了。见下。

**共享键鼠** — 见下。

**鼠标手感排查…** — 弹出 iPad 侧的设置清单（滚轮反向、一顿一顿怎么办），
并显示 Mac 当前的自然滚动状态。命令行等价物是 `uc mouse`。

## 共享键鼠开关：为什么要绕一道

系统**没有**为这个开关提供 URL scheme、命令行工具或公开 API。翻遍 `UniversalControl.app` 和 `UniversalControl.framework`（二进制在 dyld 共享缓存里，磁盘上是坏符号链接），唯一能用的入口是 `DisplaysSettingsIntentsExtension.appex` 里的一组 App Intents：

- `UpdateShareKeyboardEntityValueIntent`
- `ShareKeyboardToggle` / `ShareKeyboardQuery`
- `OpenShareKeyboardEntityDeepLink`

App Intent 只能通过「快捷指令」调用，所以需要你手动建两个快捷指令做桥：

1. 打开「快捷指令」App，新建
2. 搜索「**共享键盘和鼠标**」，添加这个动作
3. 把值设为「开」，命名为 **打开共享键鼠**
4. 再建一个，值设为「关」，命名为 **关闭共享键鼠**

然后告诉 UCMenu 这两个名字：

```sh
~/Applications/UCMenu.app/Contents/MacOS/UCMenu shortcuts 打开共享键鼠 关闭共享键鼠
```

配好后菜单里就会出现「开启 / 关闭」。没配的话会显示「尚未配置快捷指令…」，点它有帮助说明。

如果快捷指令不存在，对应菜单项会置灰并标出缺的是哪个名字，不会静默失败。

### 可选：显示开关的当前状态

再建一个快捷指令（用 `ShareKeyboardQuery` 那个查询动作），让它输出 `1` 或 `0`，然后：

```sh
~/Applications/UCMenu.app/Contents/MacOS/UCMenu shortcuts 打开共享键鼠 关闭共享键鼠 查询共享键鼠
```

菜单顶部就会多一行「当前：已开启 / 已关闭」。不配也行，只是看不到状态。

## 做不到的事

### 1. iPad 画不进排列画布

**「只共享键鼠」状态下的 iPad 不是显示器**——没有 framebuffer、没有 CGDirectDisplayID、没有坐标。`CGGetOnlineDisplayList` 永远只返回两台物理屏。所以画布上不可能出现 iPad 的方块。

这不是实现问题，是系统层面没有这个概念。对比：Crisp（`didriksg/Crisp`）同样只做物理显示器 + 虚拟显示器，README 里 Universal Control / Sidecar / iPad 一个字都没有。

要让 iPad 出现在排列里，只有一条路：**用随航（Sidecar）**。那它会变成一个真正的显示器（1180×820@2x），`ucdisplay` 和排列快照就都能管它了。

### 2. iPad 的逻辑位置改不了，只能看

iPad 在通用控制下没有 displayID，`CGConfigureDisplayOrigin` 碰不到它。位置记在 WindowServer 的显示配置里：

```
~/Library/Preferences/ByHost/com.apple.windowserver.displays.<硬件UUID>.plist
  → DisplaySets.Configs[].DisplayConfig[]     ← 条目带 OriginX / OriginY
```

直接改这个 plist 要重启 WindowServer，等于注销重登，不值得。

菜单里那条 **「iPad 位置（只读）…」** 会跑 `uc ipad`，把当前位置和历史分布摆出来：

```
  当前排列里 iPad 在 (0, 0)   ← 与主屏完全重叠
     这个位置就是它跟着主屏一起动的原因，鼠标在主屏上会直接穿过去。
```

`(0,0)` 是通用控制的**未初始化默认值**，和主屏坐标完全一样。看到它，直接去 **系统设置 → 显示器 → 排列** 把 iPad 拖开。

> 这里以前是个「保存与还原一并处理」的勾选项，1.3.3 删了。它写回的是通用控制的 `Configuration` blob，实测那张「设备↔显示器」边表是**连接事件历史**，不含位置（12 小时零变化，期间重连 4 次）；而且写回必须重启 `UniversalControl.app`，一重启 iPad 位置就被重置回 `(0,0)`。既没用又有害。

### 3. 「连接键盘和鼠标至 "V" 的 iPad」不能程序化触发

系统那 11 个 App Intent 里只有全局的 `ShareKeyboard`，没有按设备连接的。App 的 `CFBundleURLTypes` 是空的，也没有命令行参数。想硬啃就得逆向 UC 的私有 XPC 协议（`com.apple.universalcontrol.ui` 等），不划算。

所以这个程序能给你的是：**总开关 + 强制重新握手 + 一键直达设置页 + 排列快照还原 + iPad 位置只读查看**。点一下自动连上某台 iPad，系统没留这个口子。

### 4. 主屏不能拖动

主显示器的原点恒为 (0,0)，`CGConfigureDisplayOrigin` 对它无效。切换主屏需要改菜单栏所在屏，那是另一套私有 API，没做。

## 状态是怎么读的

- **进程** — `pgrep -f UniversalControl.app/Contents/MacOS/UniversalControl`
- **已配对 iPad** — `system_profiler SPBluetoothDataType` 里名字含 iPad 的条目
- **最近连接事件** — `~/Library/Preferences/ByHost/com.apple.universalcontrol.*.plist` 的修改时间（每次连接/断开都会写这个账本）
- **排列差异** — `CGGetOnlineDisplayList` + `CGDisplayBounds` 跟 `~/.config/uc/arrange.tsv` 逐台比对

菜单打开时**不做任何 IO**，全部用后台轮询好的缓存渲染，保证点开即出。快查询（进程 / 账本时间 / 排列差异）每 4 秒一次，慢查询（蓝牙设备 / 快捷指令列表）每 60 秒一次。菜单展开期间后台刷新不会重建菜单，避免闪烁。

排查用：

```sh
~/Applications/UCMenu.app/Contents/MacOS/UCMenu dump
```

不开窗口，直接把菜单要显示的内容打到终端。

## 许可

MIT
