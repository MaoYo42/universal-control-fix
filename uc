#!/bin/bash
#
# uc — macOS 通用控制（Universal Control）体检与自愈
#
#   uc               体检报告
#   uc fix           重置通用控制
#   uc watch         后台守候，掉线自动恢复
#   uc arrange       显示器排列快照（save / apply / auto / uc）
#   uc log           查看最近日志
#
# 设计原则：只用系统真实机制，不模拟点击任何 UI。
#

VERSION="1.4.0"
UC_BIN="/System/Library/CoreServices/UniversalControl.app/Contents/MacOS/UniversalControl"
UC_APP="/System/Library/CoreServices/UniversalControl.app"

# 显示器排列快照
UC_CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/uc"
UC_ARRANGE="$UC_CFG_DIR/arrange.tsv"
UC_NOAUTO="$UC_CFG_DIR/arrange.noauto"

# launchd 启动时环境变量极简，显式补齐，保证 system_profiler 等能找到
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YEL=$'\033[33m'; CYA=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GRN=''; YEL=''; CYA=''; RST=''
fi

# ─────────────────────────── 采集 ───────────────────────────

uc_pid() {
  pgrep -f "UniversalControl.app/Contents/MacOS/UniversalControl" 2>/dev/null | head -1
}

uc_uptime() {
  local pid; pid=$(uc_pid)
  [ -z "$pid" ] && return
  local e; e=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -z "$e" ] && return
  # etime 形如 05:12 / 1:05:12 / 2-03:04:05
  local days=${e%%-*} rest=$e
  case "$e" in
    *-*) rest=${e#*-} ;;
    *)   days=0 ;;
  esac
  local hh=0 mm=0 ss=0
  local n; n=$(echo "$rest" | awk -F: '{print NF}')
  if [ "$n" = "3" ]; then
    hh=$(echo "$rest" | cut -d: -f1); mm=$(echo "$rest" | cut -d: -f2); ss=$(echo "$rest" | cut -d: -f3)
  else
    mm=$(echo "$rest" | cut -d: -f1); ss=$(echo "$rest" | cut -d: -f2)
  fi
  if [ "$days" != "0" ]; then echo "${days} 天"
  elif [ "$hh" != "0" ]; then echo "${hh} 小时"
  elif [ "$mm" != "0" ]; then echo "${mm} 分钟"
  else echo "${ss} 秒"; fi
}

# 输出：band|channel|width|rssi|rate
wifi_info() {
  system_profiler SPAirPortDataType 2>/dev/null | awk '
    /Current Network Information:/ {
      inblk = 1; band = ""; chan = ""; width = ""; rssi = ""; rate = ""
      next
    }
    inblk && /^ *Channel:/ {
      v = $0; sub(/^ *Channel: */, "", v)
      chan = v; sub(/[^0-9].*$/, "", chan)
      if (v ~ /6GHz/)      band = "6GHz"
      else if (v ~ /5GHz/) band = "5GHz"
      else if (v ~ /2GHz/) band = "2.4GHz"
      width = ""
      if (match(v, /[0-9]+MHz/)) width = substr(v, RSTART, RLENGTH)
    }
    inblk && /Signal \/ Noise:/ {
      v = $0; sub(/.*Signal \/ Noise: */, "", v)
      rssi = v; sub(/ .*/, "", rssi)
    }
    inblk && /Transmit Rate:/ {
      v = $0; sub(/.*Transmit Rate: */, "", v)
      rate = v; sub(/ .*/, "", rate)
      if (band != "") print band "|" chan "|" width "|" rssi "|" rate
      exit
    }
  '
}

# 输出每行：name|minorType|rssi
bt_connected() {
  system_profiler SPBluetoothDataType 2>/dev/null | awk '
    BEGIN { sec = 0; name = ""; type = ""; rssi = "" }
    /^      Connected:/ { sec = 1; next }
    /^      Not Connected:/ {
      if (sec && name != "") print name "|" type "|" rssi
      sec = 0; name = ""; next
    }
    sec && /^          [^ ].*:$/ {
      if (name != "") print name "|" type "|" rssi
      name = $0; sub(/^ +/, "", name); sub(/:$/, "", name)
      type = ""; rssi = ""
      next
    }
    sec && /^              Minor Type:/ { v = $0; sub(/.*Minor Type: */, "", v); type = v }
    sec && /^              RSSI:/       { v = $0; sub(/.*RSSI: */, "", v); rssi = v; sub(/ .*/, "", rssi) }
    END { if (sec && name != "") print name "|" type "|" rssi }
  '
}

bt_state() {
  system_profiler SPBluetoothDataType 2>/dev/null | awk '/State:/{print $2; exit}'
}

awdl_state() {
  local f; f=$(ifconfig awdl0 2>/dev/null | head -1)
  if [ -z "$f" ]; then echo "missing"; return; fi
  case "$f" in
    *UP*RUNNING*) echo "up" ;;
    *)            echo "down" ;;
  esac
}

vpn_active() {
  local out=""
  # 系统 VPN 服务（NetworkExtension 注册的那种）
  out=$(scutil --nc list 2>/dev/null | grep -E '^[[:space:]]*\* \(Connected\)' | sed -E 's/.*"(.*)".*/\1/' | paste -sd '、' -)
  # TUN 模式代理（Shadowrocket / Clash / Surge）：scutil 看不到，只能看路由
  local tun
  tun=$(netstat -rn 2>/dev/null | awk '
    # 只认 IPv4 的 0/1、128.0/1 半区路由，或指向 fake-IP 网关的默认路由
    ($1=="0/1" || $1=="128.0/1") && $2 ~ /^[0-9]+\./ { for(i=1;i<=NF;i++) if ($i ~ /^utun[0-9]+$/) print $i; next }
    $1=="default" && $2 ~ /^198\.18\./ { for(i=1;i<=NF;i++) if ($i ~ /^utun[0-9]+$/) print $i }
  ' | sort -u | paste -sd ',' -)
  if [ -n "$tun" ]; then
    # 必须用 printf 传参：bash 3.2 里「变量展开后紧跟中文字符」会截断整串
    if [ -n "$out" ]; then
      out=$(printf '%s、TUN 代理（%s）' "$out" "$tun")
    else
      out=$(printf 'TUN 代理（%s）' "$tun")
    fi
  fi
  echo "$out"
}

# 找出被多个接口同时占用的网段（同网段多网卡会让 Bonjour 应答走错网卡）
dup_subnets() {
  netstat -rn 2>/dev/null | awk '
    {
      # 路由行末尾可能带 ! 标志，接口名要遍历字段找
      iface = ""
      for (i = 1; i <= NF; i++) if ($i ~ /^(en|bridge)[0-9]+$/) iface = $i
      if (iface == "") next
      if ($2 !~ /^link#/) next                # 只要网段路由，跳过 ARP 主机路由
      net = $1
      if (net !~ /^[0-9]+\.[0-9]+/) next      # 只看 IPv4
      if (net ~ /\//) next                    # 跳过 /32
      if (net ~ /^(22[4-9]|23[0-9])\./) next   # 跳过组播（224.0.0.251 是 mDNS，所有网卡都有）
      if (net ~ /^169\.254/) next              # 跳过链路本地（所有网卡都有）
      key = net SUBSEP iface
      if (key in seen) next
      seen[key] = 1
      list[net] = list[net] " " iface
      cnt[net]++
    }
    END { for (n in list) if (cnt[n] >= 2) print n "|" list[n] }
  '
}

ipad_names() {
  system_profiler SPBluetoothDataType 2>/dev/null \
    | grep -E '^ {10}.*iPad.*:$' | sed -E 's/^ +//; s/:$//'
}

# 按「显示宽度」右侧补空格（中文占 2 列，printf 的 %-12s 会错位）
# 纯 shell 实现：UTF-8 下 CJK 字符 3 字节 1 字符 2 列，故 宽度 = 字符数 + (字节数-字符数)/2
pad() {
  local s="$1" n="$2" chars bytes w
  bytes=$(printf '%s' "$s" | LC_ALL=C wc -c | tr -d ' ')
  chars=$(printf '%s' "$s" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
  w=$((chars + (bytes - chars) / 2))
  if [ "$w" -lt "$n" ]; then
    printf '%s%*s' "$s" $((n - w)) ''
  else
    printf '%s' "$s"
  fi
}

type_cn() {
  case "$1" in
    Headset|Headphones) echo "耳机" ;;
    Speaker)            echo "音箱" ;;
    Mouse)              echo "鼠标" ;;
    Keyboard)           echo "键盘" ;;
    Gamepad)            echo "手柄" ;;
    Trackpad)           echo "触控板" ;;
    *)                  echo "设备" ;;
  esac
}

# ─────────────────────────── 体检 ───────────────────────────

cmd_check() {
  local model osv
  model=$(sysctl -n hw.model 2>/dev/null)
  osv=$(sw_vers -productVersion 2>/dev/null)

  local is_tty=0
  if [ -t 1 ]; then is_tty=1; printf "%s正在采集系统信息…%s" "$DIM" "$RST" >&2; fi

  local w; w=$(wifi_info)
  local band chan width rssi rate
  band=$(echo "$w" | cut -d'|' -f1)
  chan=$(echo "$w" | cut -d'|' -f2)
  width=$(echo "$w" | cut -d'|' -f3)
  rssi=$(echo "$w" | cut -d'|' -f4)
  rate=$(echo "$w" | cut -d'|' -f5)

  local bts aw pid up ipads vpns btrows dups
  bts=$(bt_state); aw=$(awdl_state); pid=$(uc_pid)
  up=$(uc_uptime); ipads=$(ipad_names); vpns=$(vpn_active); btrows=$(bt_connected)
  dups=$(dup_subnets)

  [ "$is_tty" = 1 ] && printf "\r\033[K" >&2

  local LA LB LC LD LE
  LA=$(pad "Wi-Fi" 13); LB=$(pad "蓝牙" 13); LC=$(pad "点对点链路" 13)
  LD=$(pad "通用控制" 13); LE=$(pad "已配对 iPad" 13)

  local risks=0

  echo
  printf "%s通用控制体检%s  %s%s / macOS %s%s\n" "$BOLD" "$RST" "$DIM" "$model" "$osv" "$RST"
  printf "%s────────────────────────────────────────────────%s\n" "$DIM" "$RST"
  echo
  printf "%s基础条件%s\n" "$BOLD" "$RST"

  # Wi-Fi
  if [ -n "$band" ]; then
    local q=""
    if [ -n "$rssi" ] && [ "$rssi" -lt -70 ] 2>/dev/null; then q="  ← 信号偏弱"; fi
    printf "  %s✓%s %s%s · 信道 %s%s · %sdBm · %sMbps%s\n" \
      "$GRN" "$RST" "$LA" "$band" "$chan" "${width:+ ($width)}" "$rssi" "$rate" "$DIM$q$RST"
    if [ "$band" = "2.4GHz" ]; then
      printf "      %s!%s 2.4GHz 与蓝牙共用频段，通用控制容易卡顿\n" "$YEL" "$RST"
      risks=$((risks+1))
    fi
  else
    printf "  %s✗%s %s未连接 Wi-Fi —— 通用控制必须有 Wi-Fi\n" "$RED" "$RST" "$LA"
    risks=$((risks+1))
  fi

  # 蓝牙
  if [ "$bts" = "On" ]; then
    printf "  %s✓%s %s已开启\n" "$GRN" "$RST" "$LB"
  else
    printf "  %s✗%s %s已关闭 —— 通用控制必须有蓝牙\n" "$RED" "$RST" "$LB"
    risks=$((risks+1))
  fi

  # AWDL 点对点
  case "$aw" in
    up)   printf "  %s✓%s %sawdl0 正常\n" "$GRN" "$RST" "$LC" ;;
    down) printf "  %s✗%s %sawdl0 已停用 —— 关闭再打开 Wi-Fi 可恢复\n" "$RED" "$RST" "$LC"
          risks=$((risks+1)) ;;
    *)    printf "  %s✗%s %sawdl0 不存在\n" "$RED" "$RST" "$LC"
          risks=$((risks+1)) ;;
  esac

  # 通用控制进程
  if [ -n "$pid" ]; then
    local upsuf=""
    if [ -n "$up" ]; then upsuf=" · 已运行 $up"; fi
    printf "  %s✓%s %s运行中 · pid %s%s\n" "$GRN" "$RST" "$LD" "$pid" "$upsuf"
  else
    printf "  %s!%s %s未运行（按需拉起属正常；若光标跨不过去执行 uc fix）\n" "$YEL" "$RST" "$LD"
  fi

  # iPad
  if [ -n "$ipads" ]; then
    printf "  %s✓%s %s%s\n" "$GRN" "$RST" "$LE" "$(echo "$ipads" | paste -sd '、' -)"
  else
    printf "  %s!%s %s未发现已配对的 iPad\n" "$YEL" "$RST" "$LE"
  fi

  echo
  printf "%s风险项%s\n" "$BOLD" "$RST"

  # 蓝牙拥塞
  local btcount audio weak
  btcount=$(printf '%s\n' "$btrows" | grep -c '|')
  audio=$(printf '%s\n' "$btrows" | awk -F'|' '$2=="Headset"||$2=="Headphones"||$2=="Speaker"{print $1}')
  weak=$(printf '%s\n' "$btrows" | awk -F'|' '$3!="" && $3+0 < -70 {print $1}')

  if [ "${btcount:-0}" -ge 3 ] 2>/dev/null || [ -n "$audio" ] || [ -n "$weak" ]; then
    printf "  %s⚠%s 蓝牙同时连接 %s 个设备，会挤占通用控制的握手链路\n" "$YEL" "$RST" "$btcount"
    printf '%s\n' "$btrows" | awk -F'|' 'NF>=2 && $1!=""' | while IFS='|' read -r n t r; do
      [ -z "$n" ] && continue
      local note=""
      case "$t" in
        Headset|Headphones|Speaker) note="  ← 音频流最占带宽，最该断" ;;
        *) if [ -n "$r" ] && [ "$r" -lt -70 ] 2>/dev/null; then note="  ← 信号偏弱，重传多"; fi ;;
      esac
      printf "      %s %s%s%s%s\n" "$(pad "$(type_cn "$t")" 6)" "$(pad "$n" 28)" \
        "$DIM" "${r:+${r}dBm}" "$RST$note"
    done
    printf "      %s→ 不用时断开耳机和手柄，能立刻改善%s\n" "$DIM" "$RST"
    risks=$((risks+1))
  else
    printf "  %s✓%s 蓝牙负载正常（连接 %s 个设备）\n" "$GRN" "$RST" "${btcount:-0}"
  fi

  # 同网段多网卡
  if [ -n "$dups" ]; then
    printf "  %s⚠%s 多个网卡在同一网段，Bonjour 应答可能走错网卡\n" "$YEL" "$RST"
    printf '%s\n' "$dups" | while IFS='|' read -r net ifs; do
      [ -z "$net" ] && continue
      printf "      %s%s→%s %s\n" "$(pad "$net" 15)" "$DIM" "$RST" "$(echo $ifs)"
    done
    printf "      %s→ 通用控制靠 Bonjour 发现设备，多路径会导致时好时坏%s\n" "$DIM" "$RST"
    printf "      %s→ 关掉多余网卡，只留一条到 iPad 所在网络的路径%s\n" "$DIM" "$RST"
    risks=$((risks+1))
  fi

  # VPN
  if [ -n "$vpns" ]; then
    printf "  %s⚠%s VPN 已启用：%s\n" "$YEL" "$RST" "$vpns"
    printf "      %s会改写默认路由，可能干扰 iCloud 设备发现与点对点链路%s\n" "$DIM" "$RST"
    printf "      %s→ 掉线时先关掉它试试；或给它开分流，让局域网直连%s\n" "$DIM" "$RST"
    risks=$((risks+1))
  else
    printf "  %s✓%s 未检测到活动的 VPN\n" "$GRN" "$RST"
  fi

  # 显示器排列（重连后被打回默认是常见抱怨）
  if [ -n "$(ucd_bin)" ]; then
    if [ ! -f "$UC_ARRANGE" ]; then
      printf "  %s·%s 显示器排列尚未保存快照\n" "$DIM" "$RST"
      printf "      %s→ 摆好位置后执行 %suc arrange save%s%s，以后重连可一键贴回%s\n" "$DIM" "$CYA" "$RST" "$DIM" "$RST"
    else
      local apl arc
      apl=$(arrange_plan); arc=$?
      if [ "$arc" = "2" ]; then
        printf "  %s⚠%s 显示器排列读不到（ucdisplay 失效）\n" "$YEL" "$RST"
        printf "      %s→ 重新运行一次 install.sh 重装 ucdisplay%s\n" "$DIM" "$RST"
        risks=$((risks+1))
      elif [ -z "$apl" ]; then
        printf "  %s✓%s 显示器排列与快照一致\n" "$GRN" "$RST"
      else
        printf "  %s⚠%s 显示器排列与快照不一致\n" "$YEL" "$RST"
        printf '%s\n' "$apl" | while IFS=$'\t' read -r _uuid _sx _sy _rest; do
          [ -z "$_uuid" ] && continue
          printf "      %s  快照 (%s, %s)  当前 (%s)\n" "$_uuid" "$_sx" "$_sy" "$_rest"
        done
        printf "      %s→ 执行 %suc arrange apply%s%s 还原%s\n" "$DIM" "$CYA" "$RST" "$DIM" "$RST"
        risks=$((risks+1))
      fi
    fi
  fi

  echo
  printf "%s────────────────────────────────────────────────%s\n" "$DIM" "$RST"
  if [ "$risks" -eq 0 ]; then
    printf "结论：未发现明显风险项。若仍掉线，执行 %suc fix%s 重置。\n" "$CYA" "$RST"
  else
    printf "结论：%s 个风险项。处理后可执行 %suc fix%s 重置通用控制。\n" "$risks" "$CYA" "$RST"
  fi
  echo
}

# ─────────────────────── 显示器排列 ───────────────────────
#
# 重连、唤醒、显示器热插拔之后，macOS 常把副屏位置「重新居中」甚至丢到
# 主屏外面。这里做的是：把理想排列存成快照，发现漂移就贴回去（永久写入）。

# 找到 ucdisplay 二进制
ucd_bin() {
  if [ -n "$UC_DISPLAY" ] && [ -x "$UC_DISPLAY" ]; then printf '%s' "$UC_DISPLAY"; return 0; fi
  local d=""
  if [ -n "$0" ]; then d=$(cd "$(dirname "$0")" 2>/dev/null && pwd); fi
  local c
  for c in "$d/ucdisplay" "$d/tools/ucdisplay" "$HOME/bin/ucdisplay" \
           "/usr/local/bin/ucdisplay" "/opt/homebrew/bin/ucdisplay"; do
    if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  command -v ucdisplay 2>/dev/null
}

arrange_tsv() {
  local u; u=$(ucd_bin)
  [ -z "$u" ] && return 1
  "$u" list --tsv 2>/dev/null
}

# ── iPad 逻辑位置：为什么只能看、不能改 ──
#
# 这里曾经有过一套「整份备份 / 写回通用控制 Configuration」的实现，
# 后来整段删掉了，因为实测证明它没用而且有害：
#
#   · 边表 12 小时零变化。期间通用控制断连重连 4 次，边值一个都没动。
#     说明那张「设备↔显示器」边表记录的是**连接事件历史**，不是位置配置。
#   · 写回必须重启 UniversalControl 进程才会被重读，而一重启，iPad
#     断连重连，位置就被重置回 (0,0)——和主屏完全重叠。
#     等于花钱买罪受：什么都没改，反而把好位置弄没了。
#
# iPad 的真实逻辑位置在 WindowServer 的显示配置里：
#   ~/Library/Preferences/ByHost/com.apple.windowserver.displays.<uuid>.plist
#   → DisplaySets.Configs[].DisplayConfig[]，条目带 OriginX / OriginY。
# 但它没有 CGDirectDisplayID，CGConfigureDisplayOrigin 碰不到；
# 直接改 plist 又要重启 WindowServer（等于注销重登）。
# 所以结论是：**只能人手动在系统设置里拖，工具能做的是把现状读出来告诉你。**
#
# 下面保留的解码能力全部只读，不写任何东西。

ucblob_domain="com.apple.universalcontrol"

# 定位真实的 ByHost plist 文件
ucblob_path() {
  local f
  for f in "$HOME/Library/Preferences/ByHost/$ucblob_domain."*.plist; do
    if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

# 从 WindowServer 的显示配置里读 iPad 的逻辑位置（只读）。
#
# iPad 在通用控制下没有 CGDirectDisplayID，CGGetOnlineDisplayList 看不到它，
# 但 WindowServer 的持久化配置里会留一条带 OriginX/OriginY 的记录。
# 这条记录只用于「看」：能据此判断系统是不是又把它丢回 (0,0) 和主屏重叠了。
ipad_position() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf "%s·%s 需要 python3 才能解析显示配置\n" "$DIM" "$RST"
    return 1
  fi
  local ws
  ws=$(ls -t "$HOME/Library/Preferences/ByHost/com.apple.windowserver.displays."*.plist 2>/dev/null | head -1)
  if [ -z "$ws" ]; then
    printf "%s✗%s 找不到 WindowServer 显示配置\n" "$RED" "$RST"
    return 1
  fi

  # 物理屏 UUID（前 8 位）与主屏原点，由 ucdisplay 提供
  local phys main
  phys=$(arrange_tsv 2>/dev/null | cut -f1 | tr '\n' ',' | sed 's/,$//')
  main=$(arrange_tsv 2>/dev/null | awk -F'\t' '$7=="1"{printf "%s,%s,%s,%s",$2,$3,$5,$6; exit}')

  printf "\niPad 逻辑位置\n\n"
  printf "  %s配置文件：%s%s\n" "$DIM" "$(basename "$ws")" "$RST"

  python3 - "$ws" "$phys" "$main" <<'PY'
import plistlib, sys
from collections import Counter

ws, phys_s, main_s = sys.argv[1], sys.argv[2], sys.argv[3]
phys = set(x for x in phys_s.split(',') if x)
main = None      # (x, y, w, h)
if main_s and main_s.count(',') == 3:
    try:
        a, b, w, h = [float(v) for v in main_s.split(',')]
        main = (a, b, w, h)
    except ValueError:
        main = None

d = plistlib.load(open(ws, 'rb'))
cfgs = (d.get('DisplaySets') or {}).get('Configs') or []

def origin(x):
    for key in ('CurrentInfo', 'UnmirrorInfo'):
        i = x.get(key) or {}
        if i.get('OriginX') is not None:
            return i.get('OriginX'), i.get('OriginY')
    return None

# iPad 条目 = UUID 不在物理屏列表里、且尺寸像 iPad 的那条
def is_ipad(x):
    u = (x.get('UUID') or '').upper()
    if not u: return False
    if u[:8] in phys: return False
    o = origin(x)
    return o is not None

print(f"  历史配置：{len(cfgs)} 条")

# 找「含当前物理屏排列」的那条，看里面有没有 iPad
cur_cfg = None
for c in cfgs:
    dc = c.get('DisplayConfig') or []
    ids = set((x.get('UUID') or '')[:8].upper() for x in dc if isinstance(x, dict))
    if phys and ids == phys:
        cur_cfg = c
        break

ipads_in_cur = []
if cur_cfg:
    ipads_in_cur = [x for x in (cur_cfg.get('DisplayConfig') or []) if isinstance(x, dict) and is_ipad(x)]

print()
if ipads_in_cur:
    for x in ipads_in_cur:
        ox, oy = origin(x)
        tag = ''
        if main and (ox, oy) == (main[0], main[1]):
            tag = '   ← 与主屏完全重叠'
        print(f"  当前排列里 iPad 在 ({int(ox)}, {int(oy)}){tag}")
        if tag:
            print("     这个位置就是它跟着主屏一起动的原因，鼠标在主屏上会直接穿过去。")
else:
    print("  当前排列里没有 iPad 条目")
    print("     · 要么这次连接还没落盘")
    print("     · 要么通用控制暂时没给它独立位置（下次连接会重新算）")

# 历史位置统计
# 注意：这里只能靠「UUID 不在当前物理屏列表里」来筛，所以会把其他
# 已经断开的显示器也算进来（它们同样是 1920x1080）。数字看趋势，
# 别当成精确的 iPad 历史。
c = Counter()
for cfg in cfgs:
    dc = cfg.get('DisplayConfig') or []
    ids = set((x.get('UUID') or '')[:8].upper() for x in dc if isinstance(x, dict))
    # 只统计和「当前物理屏」出现在同一条配置里的非物理屏，过滤掉纯历史设备
    if phys and not (ids & phys):
        continue
    for x in dc:
        if isinstance(x, dict) and is_ipad(x):
            o = origin(x)
            if o: c[(o[0], o[1])] += 1

if c:
    print()
    print("  历史上非物理屏条目出现的位置（含 iPad 和其他已断开的显示器）：")
    for (ox, oy), n in c.most_common(6):
        note = ''
        if main:
            mx, my, mw, mh = main
            if (ox, oy) == (mx, my):
                note = '  ⚠ 和主屏重叠'
            elif ox >= mx + mw * 0.5:
                note = '  主屏右侧'
            elif ox <= mx - mw * 0.5:
                note = '  主屏左侧'
            elif oy >= my + mh * 0.5:
                note = '  主屏下方'
            elif oy <= my - mh * 0.5:
                note = '  主屏上方'
        print(f"    ({int(ox):>6}, {int(oy):>6})  {n:>2} 次{note}")

print()
print("  怎么改：")
print("    系统设置 → 显示器 → 排列，iPad 连着时会作为第三个方块出现，")
print("    直接拖到想要的位置。命令行改不了——它没有 displayID，")
print("    而改配置文件要重启 WindowServer，等于注销重登。")
print()
PY
}

# 任一显示器休眠时输出 yes。休眠状态下 WindowServer 拒绝一切排列变更。
arrange_asleep() {
  local u; u=$(ucd_bin)
  if [ -z "$u" ]; then echo "no"; return 0; fi
  local r; r=$("$u" asleep 2>/dev/null)
  echo "${r:-no}"
}

# 输出：uuid \t 快照x \t 快照y \t 当前x,当前y  （只列有差异的）
#
# 返回码有含义，调用方必须区分：
#   0  正常，输出可能为空（= 一致）
#   1  没有快照
#   2  读不到显示器数据（ucdisplay 挂了 / 没有权限）
#
# 早期版本把 2 和「一致」混在一起，结果 ucdisplay 完全失效时
# uc arrange apply 照样报「✓ 排列一致」并返回 0 —— 静默失败。
arrange_plan() {
  [ -f "$UC_ARRANGE" ] || return 1
  local cur; cur=$(mktemp /tmp/uc-arrange.XXXXXX) || return 1
  arrange_tsv > "$cur" 2>/dev/null
  if [ ! -s "$cur" ]; then
    rm -f "$cur"
    return 2
  fi
  awk -F'\t' '
    NR == FNR { sx[$1] = $2; sy[$1] = $3; next }
    ($1 in sx) && ($2 != sx[$1] || $3 != sy[$1]) {
      printf "%s\t%s\t%s\t%s,%s\n", $1, sx[$1], sy[$1], $2, $3
    }
  ' "$UC_ARRANGE" "$cur"
  rm -f "$cur"
}

# 按快照还原，还原台数写入 ARRANGE_RESTORED
arrange_restore() {
  ARRANGE_RESTORED=0
  local plan rc
  plan=$(arrange_plan); rc=$?
  [ "$rc" = "2" ] && return 1
  [ -z "$plan" ] && return 0
  local u; u=$(ucd_bin)
  [ -z "$u" ] && return 1
  local uuid sx sy rest
  while IFS=$'\t' read -r uuid sx sy rest; do
    [ -z "$uuid" ] && continue
    if "$u" set "$uuid" "$sx" "$sy" --permanent >/dev/null 2>&1; then
      printf "  %s  (%s) → (%s, %s)  %s✓%s\n" "$uuid" "$rest" "$sx" "$sy" "$GRN" "$RST"
      ARRANGE_RESTORED=$((ARRANGE_RESTORED + 1))
    else
      printf "  %s  (%s) → (%s, %s)  %s✗%s\n" "$uuid" "$rest" "$sx" "$sy" "$RED" "$RST"
    fi
  done <<EOF
$plan
EOF
}

arrange_show() {
  local u; u=$(ucd_bin)
  if [ -z "$u" ]; then
    printf "%s✗%s 找不到 ucdisplay 组件\n" "$RED" "$RST"
    printf "  %s重新运行一次 install.sh 即可装上%s\n" "$DIM" "$RST"
    return 1
  fi

  echo
  printf "%s当前显示器排列%s\n\n" "$BOLD" "$RST"
  "$u" list | tail -n +2

  if [ ! -f "$UC_ARRANGE" ]; then
    echo
    printf "%s尚未保存快照%s\n" "$YEL" "$RST"
    printf "  %s把显示器摆成你想要的样式后，执行：%suc arrange save%s\n" "$DIM" "$CYA" "$RST$DIM"
    echo
    return 0
  fi

  echo
  local plan rc
  plan=$(arrange_plan); rc=$?
  if [ "$rc" = "2" ]; then
    printf "%s✗%s 读不到显示器数据，无法比对\n" "$RED" "$RST"
    printf "  %sucdisplay 可能失效：%s list --tsv%s\n" "$DIM" "$(ucd_bin)" "$RST"
    echo
    return 1
  fi
  if [ -z "$plan" ]; then
    printf "%s✓%s 与快照一致（快照时间 %s）\n" "$GRN" "$RST" "$(date -r "$UC_ARRANGE" '+%m-%d %H:%M')"
  else
    printf "%s⚠%s 与快照不一致（快照时间 %s）\n" "$YEL" "$RST" "$(date -r "$UC_ARRANGE" '+%m-%d %H:%M')"
    printf '%s\n' "$plan" | while IFS=$'\t' read -r uuid sx sy rest; do
      [ -z "$uuid" ] && continue
      printf "    %s  快照 (%s, %s)  当前 (%s)\n" "$uuid" "$sx" "$sy" "$rest"
    done
    printf "  %s→ 执行 %suc arrange apply%s%s 还原%s\n" "$DIM" "$CYA" "$RST" "$DIM" "$RST"
  fi

  if [ -f "$UC_NOAUTO" ]; then
    printf "  %s自动还原：已关闭%s\n" "$DIM" "$RST"
  else
    printf "  %s自动还原：开启（守候模式检测到重连后会自动贴回）%s\n" "$DIM" "$RST"
  fi

  printf "  %siPad 的逻辑位置不在显示器排列里，用 %suc ipad%s%s 看%s\n" "$DIM" "$CYA" "$RST" "$DIM" "$RST"
  echo
}

arrange_save() {
  local u; u=$(ucd_bin)
  if [ -z "$u" ]; then
    printf "%s✗%s 找不到 ucdisplay 组件，请重新运行 install.sh\n" "$RED" "$RST"
    return 1
  fi
  mkdir -p "$UC_CFG_DIR" || return 1
  if ! arrange_tsv > "$UC_ARRANGE"; then
    printf "%s✗%s 保存失败\n" "$RED" "$RST"
    return 1
  fi
  local n; n=$(wc -l < "$UC_ARRANGE" | tr -d ' ')
  printf "%s✓%s 已保存 %s 台显示器的排列 → %s\n" "$GRN" "$RST" "$n" "$UC_ARRANGE"
  printf "  %s以后排列被打乱时，执行 %suc arrange apply%s%s 即可贴回%s\n" "$DIM" "$CYA" "$RST" "$DIM" "$RST"
  printf "  %s只覆盖物理显示器。iPad 的逻辑位置改不了，见 %suc ipad%s%s%s\n" "$DIM" "$CYA" "$RST" "$DIM" "$RST"
}

arrange_apply() {
  local u; u=$(ucd_bin)
  if [ -z "$u" ]; then
    printf "%s✗%s 找不到 ucdisplay 组件，请重新运行 install.sh\n" "$RED" "$RST"
    return 1
  fi
  if [ ! -f "$UC_ARRANGE" ]; then
    printf "%s✗%s 还没有快照，先摆好位置再执行 %suc arrange save%s\n" "$RED" "$RST" "$CYA" "$RST"
    return 1
  fi

  local plan rc
  plan=$(arrange_plan); rc=$?
  if [ "$rc" = "2" ]; then
    printf "%s✗%s 读不到显示器数据，无法比对\n" "$RED" "$RST"
    printf "  %sucdisplay 可能失效：%s list --tsv%s\n" "$DIM" "$u" "$RST"
    return 1
  fi
  if [ -z "$plan" ]; then
    printf "%s✓%s 显示器排列与快照一致，无需调整\n" "$GRN" "$RST"
    return 0
  fi

  # 休眠时系统会拒绝调整排列，先把屏幕叫醒
  if [ "$(arrange_asleep)" = "yes" ]; then
    printf "%s·%s 显示器休眠中，先唤醒屏幕…\n" "$YEL" "$RST"
    caffeinate -u -t 3 >/dev/null 2>&1 &
    sleep 2
    if [ "$(arrange_asleep)" = "yes" ]; then
      printf "%s✗%s 屏幕仍未唤醒，点亮屏幕后重试\n" "$RED" "$RST"
      return 1
    fi
  fi

  printf "正在还原显示器排列…\n"
  arrange_restore
  printf "%s✓%s 已还原 %s 台\n" "$GRN" "$RST" "$ARRANGE_RESTORED"
}

# 只读诊断入口：解码通用控制配置里的边表
arrange_uc() {
  case "${1:-status}" in
    edges)   ucblob_edges ;;
    *)
      local f; f=$(ucblob_path)
      if [ -n "$f" ]; then
        printf "配置文件：%s\n" "$f"
        printf "修改时间：%s\n" "$(date -r "$f" '+%m-%d %H:%M:%S')"
      else
        printf "%s✗%s 找不到通用控制配置文件\n" "$RED" "$RST"
      fi
      printf "用法：uc arrange uc edges   解码「设备↔显示器」边表（只读）\n"
      printf "      %s这张表是连接事件历史，不是位置配置；iPad 位置看 %suc ipad%s%s\n" \
        "$DIM" "$CYA" "$RST" "$DIM" ;;
  esac
}

# 把 Configuration 里的「设备↔显示器」边表摊开成人能看的样子。
# 结构：heap 里若干 8 元列表
#   [时间戳微秒, 类型(0/1/3), 会话UUID, 设备UUID, 对端UUID, 显示器UUID, 边值, 边值]
# 边值是 16 位定点数：32767(0x7FFF) 表示「无 / 居中」，65535(0xFFFF) 表示满。
ucblob_edges() {
  local src="${1:-}"
  [ -z "$src" ] && src=$(ucblob_path)
  if [ -z "$src" ] || [ ! -f "$src" ]; then
    printf "%s✗%s 没有可解析的文件：%s\n" "$RED" "$RST" "${src:-（找不到通用控制配置）}"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf "%s·%s 需要 python3 才能解码边表\n" "$DIM" "$RST"
    return 1
  fi

  python3 - "$src" <<'PY'
import plistlib, sys, subprocess, re

path = sys.argv[1]
d = plistlib.load(open(path, 'rb'))
blob = d.get('Configuration')
if not blob:
    print('没有 Configuration 键'); sys.exit(1)
inner = plistlib.loads(blob)
heap = inner.get('heap', [])
print(f"结构版本 vers={inner.get('vers')}  节点 {len(heap)} 个")

rows = []
for node in heap:
    for item in node:
        if not isinstance(item, list) or len(item) != 8:
            continue
        ts, kind, sess, dev, peer, disp, e1, e2 = item
        if not isinstance(ts, int) or not isinstance(sess, str):
            continue
        rows.append((ts, kind, sess, dev, peer, disp, e1, e2))

if not rows:
    print('没找到边表条目'); sys.exit(0)

# 时间戳是「开机以来的单调时钟」，单位纳秒（可用最新一条和文件 mtime 交叉验证）
try:
    bt = subprocess.check_output(['sysctl', '-n', 'kern.boottime']).decode()
    boot = int(re.search(r'sec = (\d+)', bt).group(1))
except Exception:
    boot = None

def fmt_edge(v):
    if v == 32767: return '无'
    if v == 65535: return '满'
    return f'{v/65535*100:.0f}%'

def fmt_ts(us):
    s = us / 1e9
    if boot is None:
        return f'+{s:.0f}s'
    return f'开机后 {int(s)//60:02d}:{int(s)%60:02d}'

# 按「对端+显示器」分组，每组取最新 3 条
groups = {}
for r in rows:
    groups.setdefault((r[4], r[5]), []).append(r)

newest = max(r[0] for r in rows)
print()
for (peer, disp), items in sorted(groups.items(), key=lambda kv: -max(x[0] for x in kv[1])):
    items.sort(key=lambda x: -x[0])
    flag = '  ← 最新' if items[0][0] == newest else ''
    print(f"对端 {peer[:8]}  →  显示器 {disp[:8]}{flag}")
    for ts, kind, sess, dev, _p, _d, e1, e2 in items[:3]:
        print(f"    {fmt_ts(ts)}  type={kind}  设备{dev[:8]}  边={fmt_edge(e1)} / {fmt_edge(e2)}")

print()
print('提示：边值 0% / 100% 是贴着那条边的比例，32767(无) 表示该方向不接。')
PY
}

arrange_auto() {
  mkdir -p "$UC_CFG_DIR" 2>/dev/null
  case "$1" in
    on)
      rm -f "$UC_NOAUTO"
      printf "%s✓%s 已开启自动还原\n" "$GRN" "$RST" ;;
    off)
      : > "$UC_NOAUTO"
      printf "%s✓%s 已关闭自动还原（uc arrange apply 仍可手动还原）\n" "$GRN" "$RST" ;;
    *)
      if [ -f "$UC_NOAUTO" ]; then printf "自动还原：已关闭\n"; else printf "自动还原：开启\n"; fi
      printf "用法：uc arrange auto on|off\n" ;;
  esac
}

cmd_arrange() {
  local sub="${1:-show}" a
  # --with-uc 在 1.3.3 删了。老文档、老脚本、肌肉记忆都可能还带着它，
  # 不能静默忽略——那会让人以为「还原了 iPad 位置」，其实什么都没做。
  for a in "$@"; do
    if [ "$a" = "--with-uc" ]; then
      printf "%s·%s --with-uc 已移除：写回通用控制配置不会改变 iPad 位置，\n" "$YEL" "$RST"
      printf "  而且写回要重启通用控制，反而会把它重置回 (0,0)。\n"
      printf "  %s用 %suc ipad%s%s 看当前位置，在系统设置 → 显示器 → 排列里手动拖%s\n" \
        "$DIM" "$CYA" "$RST" "$DIM" "$RST"
      break
    fi
  done
  case "$sub" in
    show|"")  arrange_show ;;
    save)     arrange_save ;;
    apply)    arrange_apply ;;
    auto)     arrange_auto "${2:-}" ;;
    uc)       arrange_uc "${2:-status}" ;;
    *)
      printf "未知子命令：%s\n" "$1" >&2
      printf "用法：uc arrange [show|save|apply|auto on|off|uc edges]\n" >&2
      return 1 ;;
  esac
}

# ─────────────────────────── 修复 ───────────────────────────

# 重置通用控制，成功时输出新 pid
reset_uc() {
  local pid new i
  pid=$(uc_pid)
  [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.3
    new=$(uc_pid)
    [ -n "$new" ] && { echo "$new"; return 0; }
  done
  # 系统没自动拉起就手动启动
  open "$UC_APP" 2>/dev/null
  for i in 1 2 3 4 5; do
    sleep 0.3
    new=$(uc_pid)
    [ -n "$new" ] && { echo "$new"; return 0; }
  done
  return 1
}

cmd_fix() {
  local old; old=$(uc_pid)
  echo
  if [ -n "$old" ]; then
    printf "结束旧进程 %s…" "$old"
  else
    printf "通用控制未运行，正在启动…"
  fi

  local new; new=$(reset_uc)
  if [ -n "$new" ]; then
    printf " %s✓%s 新 pid %s%s%s\n" "$GRN" "$RST" "$CYA" "$new" "$RST"
  else
    printf " %s✗%s 失败\n" "$RED" "$RST"
    printf "  请手动执行：open \"%s\"\n" "$UC_APP"
    return 1
  fi

  if [ "$(awdl_state)" != "up" ]; then
    printf "  %s!%s awdl0 未就绪，建议关闭再打开 Wi-Fi\n" "$YEL" "$RST"
  fi

  local vpns; vpns=$(vpn_active)
  if [ -n "$vpns" ]; then
    printf "  %s!%s 注意：VPN「%s」正在运行，可能会再次断开\n" "$YEL" "$RST" "$vpns"
  fi

  printf "\n下一步：把鼠标推到屏幕边缘，或从「显示器」菜单里选「链接键盘和鼠标」。\n\n"
}

# ─────────────────────────── 守候 ───────────────────────────

cmd_watch() {
  local interval="${1:-15}"
  case "$interval" in ''|*[!0-9]*) interval=15 ;; esac
  [ "$interval" -lt 5 ] && interval=5

  local last_vpn="" last_aw=""
  local last; last=$(date +%s)
  local last_sig="" last_asleep=""
  local last_drift="" drift_since=0 last_cool=0
  local ucd_bad=0   # ucdisplay 读不到数据时置 1，只在状态翻转时记一次日志

  # 让 launchd 停止服务时能立刻退出，而不是等 sleep 跑完
  trap 'exit 0' TERM INT

  printf "%s通用控制守候已启动%s（每 %s 秒检查，⌃C 退出）\n" "$BOLD" "$RST" "$interval"
  printf "%s会在休眠唤醒后、以及环境异常时自动处理%s\n\n" "$DIM" "$RST"

  if [ -f "$UC_ARRANGE" ]; then
    if [ -f "$UC_NOAUTO" ]; then
      printf "%s显示器排列快照已加载，但自动还原已关闭%s\n\n" "$DIM" "$RST"
    else
      printf "%s显示器排列快照已加载，重连后会检查并贴回%s\n\n" "$DIM" "$RST"
    fi
  fi

  while true; do
    local now; now=$(date +%s)
    local gap=$((now - last))
    local ts; ts=$(date '+%H:%M:%S')

    # 休眠/唤醒检测：循环间隔远超预期，说明机器睡过
    if [ "$gap" -gt $((interval * 3 + 10)) ]; then
      printf "[%s] 检测到休眠唤醒（间隔 %s 秒），重置通用控制…" "$ts" "$gap"
      local new; new=$(reset_uc)
      if [ -n "$new" ]; then printf " %s✓%s pid %s\n" "$GRN" "$RST" "$new"
      else printf " %s✗%s 失败\n" "$RED" "$RST"; fi
    fi
    last=$now

    # 显示器排列：休眠时不碰；屏幕唤醒、显示组合变化、或偏移稳定超过 60 秒时贴回
    if [ -f "$UC_ARRANGE" ] && [ ! -f "$UC_NOAUTO" ]; then
      local asleep; asleep=$(arrange_asleep)
      local sig; sig=$(arrange_tsv 2>/dev/null | cut -f1 | paste -sd ',' -)
      local why=""

      if [ "$last_asleep" = "yes" ] && [ "$asleep" = "no" ]; then
        why="屏幕唤醒"
      fi
      if [ -n "$last_sig" ] && [ -n "$sig" ] && [ "$sig" != "$last_sig" ]; then
        why="显示配置变动（$last_sig → $sig）"
      fi

      # 偏移稳定 60 秒才动手：手动拖动的过程中坐标一直在变，不会误触
      if [ "$asleep" = "no" ]; then
        local dr drc
        dr=$(arrange_plan 2>/dev/null); drc=$?
        if [ "$drc" = "2" ]; then
          # 读不到显示器数据。不能当成「没有偏移」，否则 ucdisplay 挂了
          # 之后自动还原会静默失效，而日志里一片正常。
          dr=""
          if [ "$ucd_bad" = "0" ]; then
            printf "[%s] %s⚠%s 读不到显示器数据，自动还原暂停（ucdisplay 失效？）\n" "$ts" "$YEL" "$RST"
            ucd_bad=1
          fi
        else
          if [ "$ucd_bad" = "1" ]; then
            printf "[%s] %s✓%s 显示器数据恢复\n" "$ts" "$GRN" "$RST"
            ucd_bad=0
          fi
          dr=$(printf '%s\n' "$dr" | cut -f1,4 | paste -sd ';' -)
        fi
        if [ -n "$dr" ]; then
          if [ "$dr" != "$last_drift" ]; then last_drift="$dr"; drift_since=$now; fi
          if [ $((now - drift_since)) -ge 60 ] && [ -z "$why" ]; then
            why="排列偏离快照超过 60 秒"
          fi
        else
          last_drift=""; drift_since=$now
        fi
      fi

      if [ "$asleep" = "no" ] && [ -n "$why" ]; then
        # 「偏移」这一路加冷却，避免还原后又立刻被还原导致来回跳
        local go=1
        if [ "$why" = "排列偏离快照超过 60 秒" ] && [ $((now - last_cool)) -lt 600 ]; then
          go=0
        fi
        if [ "$go" = "1" ]; then
          local cur_arr; cur_arr=$(arrange_plan)
          if [ -n "$cur_arr" ]; then
            printf "[%s] %s%s%s，显示器排列被打乱，正在贴回快照…\n" "$ts" "$CYA" "$why" "$RST"
            arrange_restore
            if [ "${ARRANGE_RESTORED:-0}" -gt 0 ]; then
              printf "[%s] %s✓%s 已还原 %s 台显示器位置\n" "$ts" "$GRN" "$RST" "$ARRANGE_RESTORED"
              last_cool=$now
            else
              printf "[%s] %s✗%s 还原失败，可手动执行 %suc arrange apply%s\n" "$ts" "$RED" "$RST" "$CYA" "$RST"
            fi
            last_drift=""; drift_since=$now
          fi
        fi
      fi

      if [ -n "$sig" ]; then last_sig="$sig"; fi
      last_asleep="$asleep"
    fi

    # awdl0 状态变化
    local aw; aw=$(awdl_state)
    if [ "$aw" != "up" ] && [ "$last_aw" != "bad" ]; then
      printf "[%s] %s⚠%s awdl0 异常（%s）—— 通用控制会失效，关掉再打开 Wi-Fi\n" "$ts" "$YEL" "$RST" "$aw"
      last_aw="bad"
    elif [ "$aw" = "up" ] && [ "$last_aw" = "bad" ]; then
      printf "[%s] %s✓%s awdl0 已恢复\n" "$ts" "$GRN" "$RST"
      last_aw="ok"
    fi

    # VPN 变化
    local vpns; vpns=$(vpn_active)
    if [ -n "$vpns" ] && [ "$vpns" != "$last_vpn" ]; then
      printf "[%s] %s⚠%s 检测到 VPN「%s」，通用控制可能中断\n" "$ts" "$YEL" "$RST" "$vpns"
    elif [ -z "$vpns" ] && [ -n "$last_vpn" ]; then
      printf "[%s] %s✓%s VPN 已断开\n" "$ts" "$GRN" "$RST"
    fi
    last_vpn="$vpns"

    # 后台 sleep + wait，使上面的 trap 能立即生效
    sleep "$interval" &
    wait $! 2>/dev/null
  done
}

# ─────────────────────────── 日志 ───────────────────────────

cmd_log() {
  local mins="${1:-60}"
  case "$mins" in ''|*[!0-9]*) mins=60 ;; esac
  echo
  printf "%s最近 %s 分钟通用控制相关日志%s\n\n" "$BOLD" "$mins" "$RST"
  /usr/bin/log show --last "${mins}m" --predicate 'process == "UniversalControl"' --style compact 2>/dev/null | tail -40
  echo
}

# ─────────────────── 鼠标手感（iPad 侧） ───────────────────
#
# 通用控制下，鼠标在 iPad 上的手感**不由 Mac 决定**。
# Mac 只负责把指针/滚动事件转发过去，怎么解释这些事件是 iPadOS 的事。
#
# 苹果把鼠标设置散在三个地方，这是公认的痛点：
#   通用 → 触控板与鼠标          只有 3 项
#   无障碍 → 指针控制            滚动速度 / 跟踪速度 / 指针加速度 / 指针动画
#   无障碍 → 触控 → 辅助触控     指针设备 → 追踪灵敏度 / 自定义按钮
#
# 其中「滚动速度」默认只有滑条的 1/3，是最容易被漏掉、又最影响手感的一项。
# iPadOS 26 起「辅助功能」改名叫「无障碍」，路径按新名字写。

cmd_mouse() {
  echo
  printf "%s鼠标与滚动%s\n\n" "$BOLD" "$RST"

  # 自然滚动：键不存在时系统默认开启
  local nat
  nat=$(/usr/bin/defaults read -g com.apple.swipescrolldirection 2>/dev/null)
  if [ -z "$nat" ]; then
    printf "  %s自然滚动（Mac）：开启%s（默认）\n" "$GRN" "$RST"
  elif [ "$nat" = "1" ]; then
    printf "  %s自然滚动（Mac）：开启%s\n" "$GRN" "$RST"
  else
    printf "  %s自然滚动（Mac）：关闭%s\n" "$YEL" "$RST"
  fi

  local ms; ms=$(/usr/bin/defaults read -g com.apple.mouse.scaling 2>/dev/null)
  local ts; ts=$(/usr/bin/defaults read -g com.apple.trackpad.scaling 2>/dev/null)
  printf "  %s指针速度（Mac）：鼠标 %s · 触控板 %s%s\n" \
    "$DIM" "${ms:-默认}" "${ts:-默认}" "$RST"

  local ws; ws=$(/usr/bin/defaults read -g com.apple.scrollwheel.scaling 2>/dev/null)
  [ -n "$ws" ] && printf "  %s滚轮加速（Mac）：%s%s\n" "$DIM" "$ws" "$RST"

  echo
  printf "%s通用控制下，iPad 上的手感由 iPad 自己的设置决定%s\n" "$BOLD" "$RST"
  printf "  %sMac 这边怎么调都不影响 iPad，只影响 Mac 本地%s\n" "$DIM" "$RST"
  printf "  %s苹果把鼠标设置散在三个地方，按这个顺序调：%s\n\n" "$DIM" "$RST"

  printf "  %s①%s 设置 → 通用 → 触控板与鼠标\n" "$CYA" "$RST"
  printf "      %s自然滚动%s  和上面 Mac 的值保持一致，不一致就会反向\n" "$BOLD" "$RST"
  printf "      %s实测：Mac 开着自然滚动时，iPad 关掉才是同一个方向%s\n\n" "$DIM" "$RST"

  printf "  %s②%s 设置 → 无障碍（旧版叫「辅助功能」）→ 指针控制\n" "$CYA" "$RST"
  printf "      %s滚动速度%s    最容易被漏掉的一项。默认只有滑条的 1/3，\n" "$BOLD" "$RST"
  printf "                  %s拉到最右，滚一格才真的走得动%s\n" "$DIM" "$RST"
  printf "      %s跟踪速度%s    拉到最快\n" "$BOLD" "$RST"
  printf "      %s指针加速度%s  关掉。开着时滚轮会被叠一层非线性放大，一顿一顿\n" "$BOLD" "$RST"
  printf "      %s指针动画%s    关掉。光标就不会被 App 图标「吸」进去找不着\n\n" "$BOLD" "$RST"

  printf "  %s③%s 设置 → 无障碍 → 触控 → 辅助触控 → 指针设备\n" "$CYA" "$RST"
  printf "      %s追踪灵敏度%s  ② 调完还嫌慢的话，这里能再快一档\n" "$BOLD" "$RST"
  printf "      %s设备 → 点开你的鼠标 → 自定义按钮%s\n" "$BOLD" "$RST"
  printf "                  %s可以绑截屏、通知中心、控制中心、快捷指令%s\n\n" "$DIM" "$RST"

  printf "  %s④%s 还是不顺就换触控板\n" "$CYA" "$RST"
  printf "      %s滚轮是离散步进，iPadOS 不做插值；触控板走手势，原生处理%s\n" "$DIM" "$RST"
  echo
  printf "  %sApp Store 上没有能改这件事的软件——iPadOS 不开放系统级输入拦截，%s\n" "$DIM" "$RST"
  printf "  %s第三方 App 只能处理自己窗口里的输入，改不了全系统的鼠标行为。%s\n" "$DIM" "$RST"
  echo
}

# ─────────────────────── 守候服务 ───────────────────────

UC_PLIST="$HOME/Library/LaunchAgents/local.uc.watch.plist"
UC_WATCH_LOG="$HOME/Library/Logs/uc-watch.log"
UC_LABEL="local.uc.watch"

# 找到自己的绝对路径，launchd 里不能靠 PATH
uc_self() {
  local p="$0"
  case "$p" in
    /*) printf '%s' "$p" ;;
    *)  printf '%s/%s' "$(cd "$(dirname "$p")" && pwd)" "$(basename "$p")" ;;
  esac
}

cmd_agent() {
  case "${1:-status}" in
    on|install)
      mkdir -p "$(dirname "$UC_PLIST")" "$(dirname "$UC_WATCH_LOG")"
      local self; self=$(uc_self)
      cat > "$UC_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$UC_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$self</string>
        <string>watch</string>
        <string>20</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$UC_WATCH_LOG</string>
    <key>StandardErrorPath</key><string>$UC_WATCH_LOG</string>
</dict>
</plist>
EOF
      launchctl bootout "gui/$(id -u)/$UC_LABEL" 2>/dev/null
      if launchctl bootstrap "gui/$(id -u)" "$UC_PLIST" 2>/dev/null; then
        printf "%s✓%s 守候服务已启动（日志：%s）\n" "$GRN" "$RST" "$UC_WATCH_LOG"
      else
        printf "%s·%s 已写入 %s，下次登录自动加载\n" "$YEL" "$RST" "$UC_PLIST"
        printf "  %s想马上生效：launchctl bootstrap gui/\$(id -u) \"%s\"%s\n" "$DIM" "$UC_PLIST" "$RST"
      fi
      ;;
    off|uninstall)
      launchctl bootout "gui/$(id -u)/$UC_LABEL" 2>/dev/null
      rm -f "$UC_PLIST"
      printf "%s✓%s 守候服务已移除\n" "$GRN" "$RST"
      ;;
    *)
      if [ -f "$UC_PLIST" ]; then
        printf "守候服务：已安装（%s）\n" "$UC_PLIST"
        if launchctl print "gui/$(id -u)/$UC_LABEL" >/dev/null 2>&1; then
          printf "  运行状态：%s运行中%s\n" "$GRN" "$RST"
        else
          printf "  运行状态：%s未运行%s\n" "$YEL" "$RST"
        fi
        [ -f "$UC_WATCH_LOG" ] && printf "  日志：%s（%s）\n" "$UC_WATCH_LOG" "$(date -r "$UC_WATCH_LOG" '+%m-%d %H:%M')"
      else
        printf "守候服务：未安装\n"
        printf "  %s→ %suc agent on%s%s 装上，开机自动守候%s\n" "$DIM" "$CYA" "$RST" "$DIM" "$RST"
      fi
      printf "用法：uc agent on|off\n" ;;
  esac
}

# ─────────────────────────── 入口 ───────────────────────────

usage() {
  cat <<EOF

  ${BOLD}uc${RST} — 通用控制体检与自愈  v$VERSION

  ${BOLD}用法${RST}
    uc                      体检报告
    uc fix                  重置通用控制（结束进程，系统会自动拉起）
    uc watch [秒]           守候模式，掉线或排列被打乱时自动恢复（默认 15 秒）
    uc agent on|off         开机自动守候的 launchd 服务
    uc mouse                鼠标在 iPad 上的手感排查（滚轮反向 / 不顺）
    uc ipad                 iPad 的逻辑位置现在在哪（只读）
    uc arrange save         把当前显示器排列存成快照
    uc arrange apply        把排列贴回快照
    uc arrange              查看排列与快照的差异
    uc arrange auto off     关闭守候时的自动还原
    uc arrange uc edges     解码通用控制配置里的边表（只读）
    uc log [分]             查看最近日志（默认 60 分钟）

  ${BOLD}关于排列${RST}
    重连、唤醒、插拔显示器之后，macOS 常把副屏「重新居中」甚至丢到主屏外面。
    快照存在 ~/.config/uc/arrange.tsv，还原时会永久写回显示配置。

  ${BOLD}关于 iPad 的位置${RST}
    通用控制下的 iPad 不是显示器，没有 displayID，命令行改不了它的位置，
    也不该去写通用控制的配置文件——实测那里面只有连接历史，没有位置，
    写回还会重启进程把位置重置掉。用 uc ipad 看现状，然后在
    系统设置 → 显示器 → 排列里手动拖。

  ${BOLD}说明${RST}
    只使用系统真实机制，不模拟点击任何界面，不受 macOS 版本更新影响。
    结束 UniversalControl 进程后系统会自动拉起新进程，不会破坏功能。

EOF
}

case "${1:-check}" in
  check|"")  cmd_check ;;
  fix|reset) cmd_fix ;;
  watch)     cmd_watch "$2" ;;
  mouse)     cmd_mouse ;;
  ipad)      ipad_position ;;
  agent)     cmd_agent "$2" ;;
  arrange)   shift; cmd_arrange "$@" ;;
  log)       cmd_log "$2" ;;
  -h|--help|help) usage ;;
  -v|--version) echo "uc $VERSION" ;;
  *) printf "未知命令：%s\n" "$1" >&2; usage; exit 1 ;;
esac
