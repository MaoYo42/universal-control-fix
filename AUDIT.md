# 审计记录

这份文档记录 1.3.0 之后一次系统性审计的发现，重点是**怎么发现的**和**怎么验证修好了**——
问题本身修完就过去了，方法留下来才不会再犯。

审计时间：2026-11-18 · 对应版本 1.3.1

---

## 一、审计方法

### 1. 先质疑「成功」

这个工具最大的风险不是报错，是**假成功**。用户看到绿色对勾就不会再查了，
所以每一个 `✓` 都要问：这个 ✓ 是在什么条件下得出的？条件不满足时会怎样？

具体做法：把依赖的组件**故意弄坏**，看它是否还能报成功。

```sh
# 用 /usr/bin/false 冒充 ucdisplay，模拟组件失效
UC_DISPLAY=/usr/bin/false uc arrange apply
```

这一条直接抓出了最严重的问题（见下）。

> 踩过的坑：第一次用 `/bin/false` 测试，以为修复没生效，白折腾一轮。
> **macOS 没有 `/bin/false`，只有 `/usr/bin/false`。**
> 测试桩本身不可用时，`[ -x ]` 判假，被测代码会走「组件缺失」分支而不是「组件损坏」分支，
> 两条路径行为不同，容易得出错误结论。用桩之前先确认桩真的被执行了。

### 2. 顺着「资源」查线程

GUI 程序里凡是碰 `NSScreen` / `NSView` / `NSImage` 的，都要确认在不在主线程。
查法：先列出所有后台队列，再看它们间接调用了什么。

```sh
grep -n "NSScreen\|DispatchQueue" UCMenu.swift
```

### 3. 看系统给的证据，不要只看自己写的日志

`~/Library/Logs/DiagnosticReports/` 里的崩溃报告是最诚实的：
应用自己可能来不及记日志就死了，但系统一定会写一份。

```sh
ls -lt ~/Library/Logs/DiagnosticReports/<AppName>*
```

解析要点：`termination.namespace` 和 `signal` 一起看。
`CODESIGNING` + `SIGKILL (Code Signature Invalid)` 基本只有一个原因——
运行中的 bundle 被替换了。

### 4. 有副作用的操作不能当轮询

`shortcuts run` 会执行一个快捷指令，可能弹横幅、抢焦点、改状态。
把它塞进 60 秒定时器当「查询」用，等于每分钟打扰用户一次。

判断标准：**这个操作用户手动触发时是合理的吗？** 如果只适合手动触发，就不能放定时器里。

### 5. 阻塞调用不许留在主线程

`Process` + 等待退出 = 阻塞。放在 `@objc` 动作里，就是菜单卡住。
规律：**动作方法（`@objc func doXxx`）里只做「派发到后台 + 回主线程更新」**。

### 6. 看不见的交互要能自证

菜单栏图标的点击、菜单弹没弹出来，这类交互坏了，用户只会说「点了没反应」，
而真实原因可能是：事件没送到 action、分支判断写反了、菜单弹在屏幕外面、
或者根本弹了但内容为空。四种情况从外面看一模一样。

`statusItem.menu` 就是个典型陷阱：一旦赋值，AppKit 就把点击拿去掉菜单，
`button.action` 永远不触发。代码读起来「action 明明写了」，实际是死的。
这类「接口接上了、被上层吞掉」的问题读代码发现不了。

做法是留一个自检入口，把不可观察的部分变成可打印的：

- 分支判断抽成纯函数（`wantsMenu(_:_:_:)`），用断言跑全组合，不依赖真实点击
- 弹菜单这种路径真弹一次，用挂到 `.common` 的 `Timer` 在菜单展开期间取样
  —— main queue 的块在 `NSEventTrackingRunLoopMode` 下不执行，`asyncAfter`
  在 tracking 循环里是死的，这点第一次写自检时踩过
- `cancelTracking()` 收尾，外面套一个总超时，避免自检自己挂住

---

## 二、发现的问题

### P0 — 静默失败：组件挂了还报成功

**现象**

```console
$ UC_DISPLAY=/usr/bin/false uc arrange apply
✓ 显示器排列与快照一致，无需调整
$ echo $?
0
```

`ucdisplay` 完全不可用，程序却给出绿色对勾并返回 0。

**根因**

`arrange_plan()` 用「输出是否为空」表示「有没有差异」，
而 `ucdisplay` 失败时输出**也是空的**。两种完全不同的情况被压成同一个信号。

**修法**

返回码承载三态，调用方必须区分：

| 返回码 | 含义 |
|---|---|
| 0 | 正常。输出可能为空，空 = 一致 |
| 1 | 没有快照 |
| 2 | 读不到显示器数据（组件失效 / 无权限） |

**教训**

> **用「空输出」表示否定结论，是静默失败的常见来源。**
> 只要「没有结果」和「查不到」会产出同样的输出，早晚会误报。
> 让返回码或独立的哨兵值来承担这个区分。

---

### P1 — 升级必崩：替换 bundle 时旧进程还在跑

**现象**

每次 `menu/build.sh --install` 都产生一条崩溃日志：

```
signal: SIGKILL (Code Signature Invalid)
termination: namespace CODESIGNING, indicator Launch Constraint Violation
```

**根因**

安装流程的顺序是「删旧 bundle → 拷新 bundle → 杀进程」。
旧进程还在运行时，它脚下的可执行文件被换成了另一个签名的版本，
macOS 的代码签名校验发现不匹配，直接 SIGKILL。

**修法**

把 `pkill` 提到最前面，等 0.5 秒确认进程退出，再动 bundle。

**教训**

> **替换正在运行的可执行文件 = 谋杀。**
> 任何「更新自己」的流程，第一步都必须是停掉自己。
> 这条对 launchd 托管的服务尤其重要——`KeepAlive` 会立刻把它拉起来，
> 如果拉起的是还没拷完的 bundle，会进入重启循环。

---

### P1 — 后台线程碰 AppKit

**现象**

`diffArrangement()` 在 `DispatchQueue.global` 上被调用，内部用 `NSScreen.screens`
取显示器名字。平时看不出问题，压力大时会随机崩或拿到脏数据。

**根因**

`NSScreen` 属于 AppKit，只能在主线程访问。`CGGetOnlineDisplayList` / `CGDisplayBounds`
是 CoreGraphics，线程安全——**混用的时候容易只注意到前者**。

**修法**

后台只留真正会阻塞的活（`pgrep`、文件 stat、`system_profiler`），
回到主线程再算需要 AppKit 的部分。

**教训**

> 判断标准不是「这个函数在哪一层」，而是「它会不会碰 AppKit」。
> 同一个函数里 `CGXxx` 可以后台、`NSXxx` 必须主线程，得拆开。

---

### P2 — 超时只发 SIGTERM，可能永久挂住

**现象**

`run()` 超时后发 `terminate()`（SIGTERM），然后 `waitUntilExit()`。
如果子进程忽略 SIGTERM，这里永久阻塞。

后果不只是这一次调用卡住：`fastBusy` / `slowBusy` 这两个守卫标志
永远停在 true，后台刷新**再也不会恢复**，菜单栏数据静默冻结。

**修法**

SIGTERM → 等 1 秒 → 还在就 SIGKILL。

**教训**

> 守卫标志（`xxxBusy`）的复位必须放在「一定会执行」的路径上。
> 只要有一条路径能让它停在 true，整个后台刷新就死了，而且没有任何报错。

---

### P2 — 每 4 秒无条件重建菜单

**现象**

`rebuild()` 每 4 秒 `removeAllItems()` 再重建十几个菜单项，
不管状态有没有变。不泄漏（ARC 管得住），但白造对象、白做两次 stat，
菜单还可能有细微抖动。

**修法**

状态指纹：把影响菜单外观的所有值压成一个字符串，没变就直接返回。

**教训**

> 定时刷新要先算「变了没」，再决定「重画不重画」。
> 便宜的比较（拼字符串）远比重建 UI 划算。

---

### P2 — 有副作用的调用进了定时器

**现象**

共享键鼠的开关状态只能靠「跑一个快捷指令读它的输出」来查。
原实现把它放在 60 秒定时器里，等于每分钟执行一次用户的快捷指令——
可能弹横幅、抢焦点。

**修法**

改成打开菜单时才查一次。菜单先用缓存值渲染，查到后如果变了再刷一次。

---

### P0 — 基于错误假设实现的功能：写回通用控制配置「还原 iPad 位置」

**现象**

1.3.0 加了 `--with-uc`：整份备份 `com.apple.universalcontrol.<uuid>.plist`
的 `Configuration` blob，需要时整份写回，指望把 iPad 的逻辑位置还原。
菜单里对应一个「保存与还原一并处理（实验）」的勾选项。

**它错在哪**

两个独立的错误叠在一起：

1. **那张表不是位置配置。** `Configuration` 解出来是
   `{vers:3, head, heap[52], refs}`，其中 8 元列表是
   `[时间戳, 类型(0/1/3), 会话UUID, 设备UUID, 对端UUID, 显示器UUID, 边值, 边值]`。
   实测 12 小时里通用控制断连重连 4 次（守候日志有记录），边值一个都没动。
   它是**连接事件历史**，不是位置。
2. **写回必须重启进程。** `defaults import` 之后要 kill
   `UniversalControl.app` 才会被重读。一重启，iPad 断连重连，
   位置被重置成 `(0,0)`——和主屏完全重叠，鼠标在主屏上会直接穿过去。

所以这个功能的实际效果是：什么都没改，还把好位置弄没了。

**位置到底在哪**

WindowServer 的显示配置里：

```
~/Library/Preferences/ByHost/com.apple.windowserver.displays.<uuid>.plist
  → DisplaySets.Configs[].DisplayConfig[]
```

iPad 在里面有完整坐标（本机 UUID `26EE7C3A-…`，和物理屏并列，带
`OriginX`/`OriginY`/`Wide`/`High`/`Rotation`）。但它没有
`CGDirectDisplayID`，`CGConfigureDisplayOrigin` 碰不到；直接改 plist
又要重启 WindowServer（等于注销重登）。**结论：只能人手动拖。**

**修法**

整段删除。只保留只读解码（`uc arrange uc edges`），并新增 `uc ipad`
读 WindowServer 配置报告当前位置和历史分布。菜单里的勾选项换成
「iPad 位置（只读）…」。

**教训**

> 不要因为「技术上做得到」就当成「功能有效」。
> 写回一份二进制配置能跑通、能验证字节级一致，不等于它改变了系统行为。
> 验证必须落在**用户可观察的结果**上：位置变了吗？没变就是没用。

> 一个功能如果有副作用，而这个副作用恰好会破坏它想修复的东西，
> 那它注定是负收益。设计时就要问：为了让新配置生效，我需要付出什么代价？
> 这个代价会不会抵消收益？这里的代价是重启进程，而重启进程正是位置重置的原因。

> 「实验性」标签不是免责声明。用户勾上它，就是相信它能用。

> 判断一份二进制配置是「配置」还是「日志」，看它会不会随状态变化。
> 不变的就是历史，变了才可能是配置。这条比逆出完整结构快得多。

---

### P3 — 同一份逻辑写了两遍

`install.sh` 和 `uc agent on` 各自生成一份 launchd plist。
两份实现，字段早晚会漂移。

**修法**

`install.sh` 直接调 `uc agent on`。

---

## 三、回归清单

改完这些地方之后，至少跑一遍：

```sh
# 1. 语法
bash -n uc && bash -n install.sh && bash -n menu/build.sh && bash -n dist/make-dmg.sh

# 2. 组件失效时不许报成功
UC_DISPLAY=/usr/bin/false uc arrange apply    # 期望 rc=1，且输出 ✗
UC_DISPLAY=/usr/bin/false uc                  # 期望体检里标 ⚠ 而不是 ✓

# 3. 正常路径
uc arrange                                    # 期望能列出差异或「一致」
uc arrange apply                              # 期望 rc=0
uc mouse                                      # 期望打印 iPad 侧排查清单
uc ipad                                       # 期望打印 iPad 当前位置，rc=0

# 4. 不许再有会重启通用控制的「还原」路径
grep -rn "with-uc\|ucblob_restore\|reset_uc" uc menu/UCMenu.swift
# 期望：只有 uc fix / 重新握手 会调 reset_uc，arrange 链路里一个都不许有

# 4. 升级不产生崩溃日志
ls ~/Library/Logs/DiagnosticReports/UCMenu* | wc -l
menu/build.sh --install                       # 跑两次
ls ~/Library/Logs/DiagnosticReports/UCMenu* | wc -l   # 数量不应增加

# 5. 菜单栏程序活着且数据正确
pgrep -lf "Applications/UCMenu.app/Contents/MacOS/UCMenu"
~/Applications/UCMenu.app/Contents/MacOS/UCMenu dump

# 6. 图标点击链路（分支判断 + 菜单真的能弹）
pkill -f "UCMenu.app/Contents/MacOS/UCMenu"   # 必须先退出，否则自检必假失败
~/Applications/UCMenu.app/Contents/MacOS/UCMenu selftest
# 期望：5 条断言全过、菜单展开中 items>0、本次弹出=是、退出码 0
open ~/Applications/UCMenu.app                # 自检完再拉起来
```

---

## 四、留给下次的问题

- `run()` 不并发读管道，输出超过管道缓冲区（约 64KB）会死锁到超时。
  目前最长的输出是 `system_profiler SPBluetoothDataType`（实测约 2KB），
  蓝牙设备极多时理论上会踩到。要彻底解决得改成边读边等。
- `stateSignature()` 用 `shortcuts.count` 而不是集合内容，
  快捷指令改名但数量不变时菜单不会刷新。
- `uc watch` 的自动还原每触发一次都会 `--permanent` 写一次显示配置，
  `com.apple.windowserver.displays.*.plist` 里的历史记录会持续增长。
  现在有 60 秒稳定判定 + 600 秒冷却兜着，但长期跑还是要观察。
- **iPad 的逻辑位置仍然只能手动拖。** `uc ipad` 只读，能告诉你它被放在哪、
  是不是又回到 `(0,0)` 和主屏重叠了，但改不了。理论上的路径有两条，
  都不划算：① 逆向 `CGSConfigureDisplayOrigin` 之类的私有 API，看能不能
  用一个「没有 displayID 的 UUID」配置；② 直接改 windowserver 的 plist
  再重启 WindowServer（等于注销重登）。如果以后真要试，先确认改完
  iPad 位置会不会被系统在下一次连接时覆盖掉——这次的教训就是
  「写进去了」不等于「生效了」。
