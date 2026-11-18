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

VERSION="1.3.1"
UC_BIN="/System/Library/CoreServices/UniversalControl.app/Contents/MacOS/UniversalControl"
UC_APP="/System/Library/CoreServices/UniversalControl.app"

# 显示器排列快照
UC_CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/uc"
UC_ARRANGE="$UC_CFG_DIR/arrange.tsv"
UC_NOAUTO="$UC_CFG_DIR/arrange.noauto"
UC_UCBLOB="$UC_CFG_DIR/uc-config.plist"
UC_RESTOREUC="$UC_CFG_DIR/restore-uc"   # 存在 = 还原排列时一并还原 iPad 位置

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

# ── 通用控制配置账本 ──
#
# 通用控制下的 iPad 不是显示器：CGGetOnlineDisplayList 里永远看不到它，
# 没有 framebuffer、没有 UUID、没有坐标，所以挪不动它。
# 它挂在显示器哪条边，记录在
#   ~/Library/Preferences/ByHost/com.apple.universalcontrol.<硬件UUID>.plist
# 的 Configuration 二进制 blob 里（设备↔显示器 边表）。
# 单个字段无法直接改写，只能整份备份、整份写回，再让进程重读。
#
# 走 defaults export/import 而不是 cp：写入由 cfprefsd 自己完成，
# 不会被它的内存缓存覆盖回去，也就不需要 killall cfprefsd。

ucblob_domain="com.apple.universalcontrol"

# 定位真实的 ByHost plist 文件
ucblob_path() {
  local f
  for f in "$HOME/Library/Preferences/ByHost/$ucblob_domain."*.plist; do
    if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

# 导出当前配置到 $UC_UCBLOB
ucblob_save() {
  mkdir -p "$UC_CFG_DIR" 2>/dev/null
  if ! /usr/bin/defaults -currentHost export "$ucblob_domain" "$UC_UCBLOB" 2>/dev/null; then
    printf "  %s✗%s 读取通用控制配置失败\n" "$RED" "$RST"
    return 1
  fi
  local sz; sz=$(wc -c < "$UC_UCBLOB" | tr -d ' ')
  printf "  %s✓%s 已保存通用控制配置（%s 字节，含 iPad 边表）\n" "$GRN" "$RST" "$sz"
}

# 把 $UC_UCBLOB 写回系统，并重启通用控制让它重读
ucblob_restore() {
  if [ ! -f "$UC_UCBLOB" ]; then
    printf "  %s·%s 没有通用控制配置快照，跳过 iPad 位置还原\n" "$DIM" "$RST"
    return 0
  fi
  local dst; dst=$(ucblob_path)
  if [ -z "$dst" ]; then
    printf "  %s✗%s 找不到通用控制配置文件\n" "$RED" "$RST"
    return 1
  fi

  # 先留回退，写坏了还能捞回来
  cp "$dst" "$UC_UCBLOB.bak" 2>/dev/null

  local cur; cur=$(mktemp /tmp/uc-blob.XXXXXX) || return 1
  /usr/bin/defaults -currentHost export "$ucblob_domain" "$cur" 2>/dev/null
  if cmp -s "$UC_UCBLOB" "$cur"; then
    rm -f "$cur"
    printf "  %s·%s 配置与快照一致，无需写回\n" "$DIM" "$RST"
    return 0
  fi
  rm -f "$cur"

  if ! /usr/bin/defaults -currentHost import "$ucblob_domain" "$UC_UCBLOB" 2>/dev/null; then
    printf "  %s✗%s 写回通用控制配置失败\n" "$RED" "$RST"
    return 1
  fi
  printf "  %s✓%s 已写回配置，重启通用控制让它重读…\n" "$GRN" "$RST"

  local newpid; newpid=$(reset_uc)
  if [ -n "$newpid" ]; then
    printf "  %s✓%s 通用控制已重启（pid %s）\n" "$GRN" "$RST" "$newpid"
  else
    printf "  %s⚠%s 通用控制没起来，稍等它会被系统拉起\n" "$YEL" "$RST"
  fi
  sleep 1
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

  # iPad 逻辑位置账本
  if [ -f "$UC_UCBLOB" ]; then
    printf "  %s iPad 位置快照：已保存（%s）%s\n" "$DIM" "$(date -r "$UC_UCBLOB" '+%m-%d %H:%M')" "$RST"
  else
    printf "  %s iPad 位置快照：未保存 → %suc arrange save --with-uc%s\n" "$DIM" "$CYA" "$RST"
  fi
  echo
}

arrange_save() {
  local withuc="$1"
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

  # iPad 位置一并存进通用控制配置账本
  if [ "$withuc" = "yes" ]; then
    ucblob_save
  fi

  printf "  %s以后排列被打乱时，执行 %suc arrange apply%s%s 即可贴回%s\n" "$DIM" "$CYA" "$RST" "$DIM" "$RST"
  if [ "$withuc" != "yes" ]; then
    printf "  %s想连 iPad 的逻辑位置一起存，加 %s--with-uc%s\n" "$DIM" "$CYA" "$RST"
  fi
}

arrange_apply() {
  local withuc="$1"
  local u; u=$(ucd_bin)
  if [ -z "$u" ]; then
    printf "%s✗%s 找不到 ucdisplay 组件，请重新运行 install.sh\n" "$RED" "$RST"
    return 1
  fi
  if [ ! -f "$UC_ARRANGE" ]; then
    printf "%s✗%s 还没有快照，先摆好位置再执行 %suc arrange save%s\n" "$RED" "$RST" "$CYA" "$RST"
    return 1
  fi

  # 没显式传参时，看菜单栏程序留下的开关
  if [ -z "$withuc" ] && [ -f "$UC_RESTOREUC" ]; then withuc="yes"; fi

  # ① iPad 逻辑位置：先做，因为写回配置会重启通用控制
  if [ "$withuc" = "yes" ]; then
    printf "正在还原 iPad 逻辑位置…\n"
    ucblob_restore
  fi

  # ② 显示器排列
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

# iPad 位置账本的独立入口，方便单独验证
arrange_uc() {
  case "${1:-status}" in
    save)    ucblob_save ;;
    restore) ucblob_restore ;;
    edges)   ucblob_edges ;;
    diff)    ucblob_diff ;;
    *)
      local f; f=$(ucblob_path)
      if [ -n "$f" ]; then
        printf "配置文件：%s\n" "$f"
        printf "修改时间：%s\n" "$(date -r "$f" '+%m-%d %H:%M:%S')"
      else
        printf "%s✗%s 找不到通用控制配置文件\n" "$RED" "$RST"
      fi
      if [ -f "$UC_UCBLOB" ]; then
        printf "快照：已保存（%s 字节，%s）\n" \
          "$(wc -c < "$UC_UCBLOB" | tr -d ' ')" "$(date -r "$UC_UCBLOB" '+%m-%d %H:%M')"
      else
        printf "快照：尚未保存 → %suc arrange save --with-uc%s\n" "$CYA" "$RST"
      fi
      printf "用法：uc arrange uc [save|restore|edges|diff]\n" ;;
  esac
}

# 比对快照与当前配置的边表，看「对端→显示器」的最新边值有没有变
ucblob_diff() {
  local live; live=$(ucblob_path)
  if [ -z "$live" ]; then
    printf "%s✗%s 找不到通用控制配置文件\n" "$RED" "$RST"; return 1
  fi
  if [ ! -f "$UC_UCBLOB" ]; then
    printf "%s✗%s 还没有快照，先执行 %suc arrange uc save%s\n" "$RED" "$RST" "$CYA" "$RST"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf "%s·%s 需要 python3 才能解码边表\n" "$DIM" "$RST"; return 1
  fi
  python3 - "$UC_UCBLOB" "$live" <<'PY'
import plistlib, sys

def load(path):
    d = plistlib.load(open(path, 'rb'))
    inner = plistlib.loads(d['Configuration'])
    newest = {}
    for node in inner.get('heap', []):
        for item in node:
            if not isinstance(item, list) or len(item) != 8:
                continue
            ts, kind, sess, dev, peer, disp, e1, e2 = item
            if not isinstance(ts, int) or not isinstance(sess, str):
                continue
            k = (peer, disp)
            if k not in newest or ts > newest[k][0]:
                newest[k] = (ts, e1, e2)
    return newest

snap, live = load(sys.argv[1]), load(sys.argv[2])

def fe(v):
    if v == 32767: return '无'
    if v == 65535: return '满'
    return f'{v/65535*100:.0f}%'

keys = sorted(set(snap) | set(live), key=lambda k: -max(
    (snap.get(k, (0,))[0], live.get(k, (0,))[0])))
changed = 0
for k in keys:
    s, l = snap.get(k), live.get(k)
    se = f"{fe(s[1])} / {fe(s[2])}" if s else '（快照无）'
    le = f"{fe(l[1])} / {fe(l[2])}" if l else '（现在无）'
    if s and l and s[1:] == l[1:]:
        continue
    changed += 1
    print(f"对端 {k[0][:8]}  →  显示器 {k[1][:8]}")
    print(f"    快照 {se}")
    print(f"    现在 {le}")

if changed == 0:
    print('边表与快照完全一致——说明这段时间里没有任何位置变化被记录。')
else:
    print()
    print(f'共 {changed} 组边表有变化。')
PY
}

# 把 Configuration 里的「设备↔显示器」边表摊开成人能看的样子。
# 结构：heap 里若干 8 元列表
#   [时间戳微秒, 类型(0/1/3), 会话UUID, 设备UUID, 对端UUID, 显示器UUID, 边值, 边值]
# 边值是 16 位定点数：32767(0x7FFF) 表示「无 / 居中」，65535(0xFFFF) 表示满。
ucblob_edges() {
  local src="${1:-}"
  [ -z "$src" ] && src="$UC_UCBLOB"
  if [ ! -f "$src" ]; then
    printf "%s✗%s 没有可解析的文件：%s\n" "$RED" "$RST" "$src"
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
  local sub="${1:-show}"
  local withuc="" a
  for a in "$@"; do
    [ "$a" = "--with-uc" ] && withuc="yes"
  done
  case "$sub" in
    show|"")  arrange_show ;;
    save)     arrange_save "$withuc" ;;
    apply)    arrange_apply "$withuc" ;;
    auto)     arrange_auto "${2:-}" ;;
    uc)       arrange_uc "${2:-status}" ;;
    *)
      printf "未知子命令：%s\n" "$1" >&2
      printf "用法：uc arrange [show|save|apply|auto on|off|uc save|uc restore]\n" >&2
      printf "      %suc arrange apply --with-uc%s  连 iPad 逻辑位置一起还原\n" "$CYA" "$RST" >&2
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
# 所以调 Mac 的设置没用，得去 iPad 上调。
#
# 实测有效的两条（本机验证过）：
#   1. iPad「自然滚动」要和 Mac 的一致，否则滚轮方向相反
#   2. iPad 指针速度拉到最快、关掉指针加速度，滚轮才线性

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
  printf "  %sMac 这边怎么调都不影响 iPad，只影响 Mac 本地%s\n\n" "$DIM" "$RST"

  printf "  %s1%s 设置 → 通用 → 触控板与鼠标 → %s自然滚动%s\n" "$CYA" "$RST" "$BOLD" "$RST"
  printf "      %s和上面 Mac 的值保持一致。不一致就会反向。%s\n" "$DIM" "$RST"
  printf "      %s实测：Mac 开着自然滚动时，iPad 关掉才是同一个方向。%s\n\n" "$DIM" "$RST"

  printf "  %s2%s 设置 → 辅助功能 → 指针控制\n" "$CYA" "$RST"
  printf "      %s跟踪速度拉到最快，关掉「指针加速度」%s\n" "$DIM" "$RST"
  printf "      %s加速度开着时滚轮会「一顿一顿」，关掉后线性得多%s\n\n" "$DIM" "$RST"

  printf "  %s3%s 还是不顺的话：%s换触控板%s\n" "$CYA" "$RST" "$BOLD" "$RST"
  printf "      %s滚轮是离散步进，iPadOS 不做插值；触控板走手势，iPadOS 原生处理%s\n" "$DIM" "$RST"
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
    uc arrange save         把当前显示器排列存成快照
    uc arrange apply        把排列贴回快照
    uc arrange              查看排列与快照的差异
    uc arrange auto off     关闭守候时的自动还原
    uc arrange save --with-uc   连 iPad 位置一起存（实验）
    uc arrange uc           查看 iPad 位置账本
    uc log [分]             查看最近日志（默认 60 分钟）

  ${BOLD}关于排列${RST}
    重连、唤醒、插拔显示器之后，macOS 常把副屏「重新居中」甚至丢到主屏外面。
    快照存在 ~/.config/uc/arrange.tsv，还原时会永久写回显示配置。

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
  agent)     cmd_agent "$2" ;;
  arrange)   shift; cmd_arrange "$@" ;;
  log)       cmd_log "$2" ;;
  -h|--help|help) usage ;;
  -v|--version) echo "uc $VERSION" ;;
  *) printf "未知命令：%s\n" "$1" >&2; usage; exit 1 ;;
esac
