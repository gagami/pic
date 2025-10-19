#!/bin/bash
# ============================================================
# 🧩 CyberOps MOTD+ (Dark Cyber Monitoring Edition)
# 作者: yagami + ChatGPT
# 版本: v2.0 | Ubuntu / Debian 通用
# ============================================================

RESET="\033[0m"
CYBER="\033[38;5;81m"
NEON="\033[38;5;129m"
GRAY="\033[38;5;240m"
YELLOW="\033[1;33m"

# 获取基础系统信息
HOSTNAME=$(hostname)
OS=$(lsb_release -d | awk -F"\t" '{print $2}')
KERNEL=$(uname -r)
UPTIME=$(uptime -p | sed 's/up //')
LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
MEM_USED=$(free -m | awk '/Mem:/ {printf("%dMB / %dMB", $3, $2)}')
IP_ADDR=$(hostname -I | awk '{print $1}')
LOGIN_TIME=$(date "+%Y-%m-%d %H:%M:%S")
USER=$(whoami)

# 磁盘使用率
DISK_USAGE=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')

# 网络接口与流量速率
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
if [[ -n "$INTERFACE" ]]; then
  RX_PRE=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
  TX_PRE=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)
  sleep 0.5
  RX_NOW=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
  TX_NOW=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)
  RX_RATE=$(( (RX_NOW - RX_PRE) * 2 / 1024 ))
  TX_RATE=$(( (TX_NOW - TX_PRE) * 2 / 1024 ))
else
  RX_RATE=0; TX_RATE=0
  INTERFACE="N/A"
fi

# 当前监听端口
LISTEN_COUNT=$(ss -tuln | grep -c LISTEN)

# 登录地理位置
PUB_IP=$(curl -s https://ipinfo.io/ip)
if [[ -n "$PUB_IP" ]]; then
  GEO_INFO=$(curl -s https://ipinfo.io/${PUB_IP}/city)
  COUNTRY=$(curl -s https://ipinfo.io/${PUB_IP}/country)
  LOCATION="${GEO_INFO:-未知}/${COUNTRY:---}"
else
  LOCATION="未知"
fi

# ──────────────── ASCII CYBER LOGO ────────────────
cat << "EOF"
  ▄ ▄   ▄███▄   █     ▄█▄    ████▄ █▀▄▀█ ▄███▄       ▀▄    ▄ ██     ▄▀  ██   █▀▄▀█ ▄█       ▄
 █   █  █▀   ▀  █     █▀ ▀▄  █   █ █ █ █ █▀   ▀        █  █  █ █  ▄▀    █ █  █ █ █ ██      █
█ ▄   █ ██▄▄    █     █   ▀  █   █ █ ▄ █ ██▄▄           ▀█   █▄▄█ █ ▀▄  █▄▄█ █ ▄ █ ██     █
█  █  █ █▄   ▄▀ ███▄  █▄  ▄▀ ▀████ █   █ █▄   ▄▀        █    █  █ █   █ █  █ █   █ ▐█     █
 █ █ █  ▀███▀       ▀ ▀███▀           █  ▀███▀        ▄▀        █  ███     █    █   ▐
  ▀ ▀                                ▀                         █          █    ▀          ▀
  ┌───┐   ┌───┬───┬───┬───┐ ┌───┬───┬───┬───┐ ┌───┬───┬───┬───┐ ┌───┬───┬───┐
  │Esc│   │ F1│ F2│ F3│ F4│ │ F5│ F6│ F7│ F8│ │ F9│F10│F11│F12│ │P/S│S L│P/B│  ┌┐    ┌┐    ┌┐
  └───┘   └───┴───┴───┴───┘ └───┴───┴───┴───┘ └───┴───┴───┴───┘ └───┴───┴───┘  └┘    └┘    └┘
  ┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───────┐ ┌───┬───┬───┐ ┌───┬───┬───┬───┐
  │~ `│! 1│@ 2│# 3│$ 4│% 5│^ 6│& 7│* 8│( 9│) 0│_ -│+ =│ BacSp │ │Ins│Hom│PUp│ │N L│ / │ * │ - │
  ├───┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─────┤ ├───┼───┼───┤ ├───┼───┼───┼───┤
  │ Tab │ Q │ W │ E │ R │ T │ Y │ U │ I │ O │ P │{ [│} ]│ | \ │ │Del│End│PDn│ │ 7 │ 8 │ 9 │   │
  ├─────┴─┬──┴┬──┴┬──┴┬──┴┬──┴┬──┴┬──┴┬──┴┬──┴┬──┴┬──┴┬──┴─────┤ └───┴───┴───┘ ├───┼───┼───┤ + │
  │ Caps │ A │ S │ D │ F │ G │ H │ J │ K │ L │: ;│" '│ Enter  │               │ 4 │ 5 │ 6 │   │
  ├──────┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴────────┤     ┌───┐     ├───┼───┼───┼───┤
  │ Shift  │ Z │ X │ C │ V │ B │ N │ M │< ,│> .│? /│  Shift   │     │ ↑ │     │ 1 │ 2 │ 3 │   │
  ├─────┬──┴─┬─┴──┬┴───┴───┴───┴───┴───┴──┬┴───┼───┴┬────┬────┤ ┌───┼───┼───┐ ├───┴───┼───┤ E││
  │ Ctrl│    │Alt │         Space         │ Alt│    │    │Ctrl│ │ ← │ ↓ │ → │ │   0   │ . │←─┘│
  └─────┴────┴────┴───────────────────────┴────┴────┴────┴────┘ └───┴───┴───┘ └───────┴───┴───┘
EOF

# ──────────────── 系统信息 ────────────────
echo -e "${CYBER}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
printf " 🖥️ Hostname  : ${CYBER}%s${RESET}\n" "$HOSTNAME"
printf " 🧠 OS         : ${CYBER}%s${RESET}\n" "$OS"
printf " ⚙️ Kernel     : ${CYBER}%s${RESET}\n" "$KERNEL"
printf " 🕓 Uptime     : ${CYBER}%s${RESET}\n" "$UPTIME"
printf " 💾 Memory     : ${CYBER}%s${RESET}\n" "$MEM_USED"
printf " 🔧 Load Avg   : ${CYBER}%s${RESET}\n" "$LOAD"
printf " 💽 Disk Usage : ${CYBER}%s${RESET}\n" "$DISK_USAGE"
printf " 🌐 Interface  : ${CYBER}%s${RESET}  (${GRAY}RX:${RESET}${CYBER}%s${RESET} KB/s | ${GRAY}TX:${RESET}${CYBER}%s${RESET} KB/s)\n" "$INTERFACE" "$RX_RATE" "$TX_RATE"
printf " 🔒 Listening  : ${CYBER}%s${RESET} ports active\n" "$LISTEN_COUNT"
echo -e "${CYBER}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

# ──────────────── 登录信息 ────────────────
printf " 👤 User       : ${YELLOW}%s${RESET}\n" "$USER"
printf " ⏰ LoginTime  : ${CYBER}%s${RESET}\n" "$LOGIN_TIME"
printf " 📍 Location   : ${CYBER}%s${RESET} (${GRAY}%s${RESET})\n" "$LOCATION" "$PUB_IP"
echo -e "${CYBER}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
cat <<EOF
⚡ 怪叔叔的领悟
EOF
echo
