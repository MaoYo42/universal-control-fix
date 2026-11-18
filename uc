#!/bin/bash
#
# uc — macOS 通用控制（Universal Control）体检与自愈
#
#   uc           体检报告
#   uc fix       重置通用控制
#   uc watch     后台守候，掉线自动恢复
#   uc log       查看最近日志
#
# 设计原则：只用系统真实机制，不模拟点击任何 UI。
#

VERSION="1.1.0"
UC_BIN="/System/Library/CoreServices/UniversalControl.app/Contents/MacOS/UniversalControl"
UC_APP="/System/Library/CoreServices/UniversalControl.app"

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
  scutil --nc list 2>/dev/null | grep -E '^\s*\* \(Connected\)' | sed -E 's/.*"(.*)".*/\1/'
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

  local bts aw pid up ipads vpns btrows
  bts=$(bt_state); aw=$(awdl_state); pid=$(uc_pid)
  up=$(uc_uptime); ipads=$(ipad_names); vpns=$(vpn_active); btrows=$(bt_connected)

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
    printf "  %s✓%s %s运行中 · pid %s%s\n" "$GRN" "$RST" "$LD" "$pid" "${up:+ · 已运行 $up}"
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

  # VPN
  if [ -n "$vpns" ]; then
    printf "  %s⚠%s VPN 已启用：%s\n" "$YEL" "$RST" "$(echo "$vpns" | paste -sd '、' -)"
    printf "      %s全隧道会切断 awdl0，通用控制 / 随航 / AirDrop 会一起失效%s\n" "$DIM" "$RST"
    printf "      %s→ 掉线时先关 VPN，或给它开分流白名单%s\n" "$DIM" "$RST"
    risks=$((risks+1))
  else
    printf "  %s✓%s 未检测到活动的 VPN\n" "$GRN" "$RST"
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

  # 让 launchd 停止服务时能立刻退出，而不是等 sleep 跑完
  trap 'exit 0' TERM INT

  printf "%s通用控制守候已启动%s（每 %s 秒检查，⌃C 退出）\n" "$BOLD" "$RST" "$interval"
  printf "%s会在休眠唤醒后、以及环境异常时自动处理%s\n\n" "$DIM" "$RST"

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

# ─────────────────────────── 入口 ───────────────────────────

usage() {
  cat <<EOF

  ${BOLD}uc${RST} — 通用控制体检与自愈  v$VERSION

  ${BOLD}用法${RST}
    uc            体检报告
    uc fix        重置通用控制（结束进程，系统会自动拉起）
    uc watch [秒] 守候模式，进程消失时自动恢复（默认 15 秒）
    uc log [分]   查看最近日志（默认 60 分钟）

  ${BOLD}说明${RST}
    只使用系统真实机制，不模拟点击任何界面，不受 macOS 版本更新影响。
    结束 UniversalControl 进程后系统会自动拉起新进程，不会破坏功能。

EOF
}

case "${1:-check}" in
  check|"")  cmd_check ;;
  fix|reset) cmd_fix ;;
  watch)     cmd_watch "$2" ;;
  log)       cmd_log "$2" ;;
  -h|--help|help) usage ;;
  -v|--version) echo "uc $VERSION" ;;
  *) printf "未知命令：%s\n" "$1" >&2; usage; exit 1 ;;
esac
