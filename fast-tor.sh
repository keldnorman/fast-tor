#!/bin/bash
#-----------------------------------------------------------------------------
# Info
#-----------------------------------------------------------------------------
# (C)opyleft Keld Norman 2025
#
# Fast-tor - V11.6
#
# Description:
#
# Starts up a lot of tor clients - with a HAProxy load balancer in front. 
# Starts up a local aria2 parallel downloader
# Multi-node Tor SOCKS rotator with HAProxy load balancing.
#
# Hardened RPC and spoofed User-Agent (Firefox/144) for improved stealth.
#-----------------------------------------------------------------------------
# Control Variables
#-----------------------------------------------------------------------------
DEBUG=0
VERSION="11.6"
APP_NAME="Fast-tor"
NUM_INSTANCES=10
#-----------------------------------------------------------------------------
# Global Variables
#-----------------------------------------------------------------------------
PAD=${#NUM_INSTANCES}
if [ $NUM_INSTANCES -lt 50 ]; then
 MIN_READY=$((NUM_INSTANCES * 50 / 100))
else
 MIN_READY=$((NUM_INSTANCES * 80 / 100))
fi
TEMP_DIR="$BASE_DIR/tor_rotator_$(date +%s)"
WELCOME_FILE="$TEMP_DIR/welcome.html"
BASE_SOCKS_PORT=9050
HAPROXY_PORT=3128
STATS_PORT=4444
ARIA2_RPC_PORT=6800
LOCAL_GUI_PORT=8080
MEM_PER_NODE=$((150 * 1024 * 1024))
DISK_PER_NODE=$((10 * 1024 * 1024))
REAL_USER=$(logname)
USER_HOME=$(eval echo ~$REAL_USER)
TBB_SEARCH_PATHS=("${USER_HOME}/.local/share/torbrowser/tbb/x86_64/tor-browser" "${USER_HOME}/.local/share/torbrowser-launcher/download/tbb.x86_64.en-US/tor-browser_en-US" "${USER_HOME}/tor-browser")
LINE="-------------------------------------------------------------------"
#-----------------------------------------------------------------------------
# Resource Logic
#-----------------------------------------------------------------------------
FREE_MEM=$(free -b | awk '/^Mem:/{print $4}')
FREE_DISK=$(df -B1 /tmp | tail -1 | awk '{print $4}')
FREE_SHM=$(df -B1 /dev/shm 2>/dev/null | tail -1 | awk '{print $4}' || echo 0)
MAX_SAFE_BY_RAM=$((FREE_MEM / MEM_PER_NODE))
MAX_SAFE_BY_DISK=$((FREE_DISK / DISK_PER_NODE))
TOTAL_MEM_REQ=$((MEM_PER_NODE * NUM_INSTANCES))
TOTAL_DISK_REQ=$((DISK_PER_NODE * NUM_INSTANCES))
SAFE_RAM_LIMIT=$((FREE_MEM * 85 / 100))
#-----------------------------------------------------------------------------
# Pre
#-----------------------------------------------------------------------------
if [ $TOTAL_MEM_REQ -gt $SAFE_RAM_LIMIT ]; then
 echo -e "\e[31m[!] DANGER: Resource request too high!\e[0m"
 echo "Requested nodes ($NUM_INSTANCES) require ~$((TOTAL_MEM_REQ / 1024 / 1024)) MB RAM."
 echo "Safe limit for your system is ~$((SAFE_RAM_LIMIT / 1024 / 1024)) MB RAM."
 echo "Recommended max nodes: $MAX_SAFE_BY_RAM"
 exit 1
fi
if [[ $FREE_SHM -gt $TOTAL_DISK_REQ ]] && [[ $FREE_MEM -gt $TOTAL_MEM_REQ ]]; then
 BASE_DIR="/dev/shm"
 STORAGE_TYPE="Memory"
else
 if [[ $FREE_DISK -lt $TOTAL_DISK_REQ ]]; then
  echo -e "\e[31m[!] CRITICAL: Not enough space!\e[0m"
  exit -1
 fi
 BASE_DIR="/tmp"
 STORAGE_TYPE="Disk"
fi
mkdir -p "$TEMP_DIR"
#-----------------------------------------------------------------------------
# Cleanup Function
#-----------------------------------------------------------------------------
cleanup() {
 printf "\r[!] Browser session ended.                                    \n"
 printf "[*] Cleaning up...                                            \n"
 trap - SIGINT SIGTERM EXIT
 set +m
 pkill -9 -f "aria2c.*$ARIA2_RPC_PORT" 2>/dev/null
 pkill -9 -f "python3 -m http.server $LOCAL_GUI_PORT" 2>/dev/null
 if command -v fuser >/dev/null; then
  fuser -k "$TEMP_DIR" 2>/dev/null
  fuser -k $LOCAL_GUI_PORT/tcp 2>/dev/null
 fi
 find "$TEMP_DIR" -maxdepth 4 -type d \( -name ".gvfs" -o -name "doc" \) -exec umount -l {} + 2>/dev/null
 pkill -9 -f "$TEMP_DIR" 2>/dev/null
 pkill -9 -P $$ 2>/dev/null
 rm -rf "$TEMP_DIR" 2>/dev/null
 exit 0
}
trap cleanup SIGINT SIGTERM
#-----------------------------------------------------------------------------
# Tor Browser Installer
#-----------------------------------------------------------------------------
install_tor_browser() {
 local TBB_VERSION="14.0.5" 
 local ARCH="linux-x86_64"
 local DOWNLOAD_URL="https://www.torproject.org/dist/torbrowser/$TBB_VERSION/tor-browser-$ARCH-$TBB_VERSION.tar.xz"
 local TARGET_DIR="$USER_HOME/tor-browser"
 printf "[!] Tor Browser not found. Installing to $TARGET_DIR...\n"
 mkdir -p "$TARGET_DIR"
 wget -q --show-progress -O "$TEMP_DIR/tbb.tar.xz" "$DOWNLOAD_URL"
 if [ $? -eq 0 ]; then
  tar -xf "$TEMP_DIR/tbb.tar.xz" -C "$USER_HOME"
  rm "$TEMP_DIR/tbb.tar.xz"
  chown -R "$REAL_USER":"$REAL_USER" "$TARGET_DIR"
  echo "[OK] Tor Browser installed successfully."
 else
  echo "[FAILED] Could not download Tor Browser."
  exit 1
 fi
}
#-----------------------------------------------------------------------------
# Dependency Check
#-----------------------------------------------------------------------------
check_dependencies() {
 local DEPS=("tor" "haproxy" "pkill" "fuser" "aria2c" "python3" "wget" "unzip" "tar" "xz")
 local MISSING=()
 local UPDATED=0
 for cmd in "${DEPS[@]}"; do
  if ! command -v "$cmd" &> /dev/null; then MISSING+=("$cmd"); fi
 done
 if [ ${#MISSING[@]} -gt 0 ]; then
  for pkg in "${MISSING[@]}"; do
   if [ $UPDATED -eq 0 ]; then 
    printf "[*] %-33s" "Updating package lists (apt)..."
    apt-get update -y &>/dev/null
    echo "[OK]"
    UPDATED=1
   fi
   local INSTALL_PKG=$pkg
   [[ "$pkg" == "pkill" ]] && INSTALL_PKG="procps"
   [[ "$pkg" == "fuser" ]] && INSTALL_PKG="psmisc"
   [[ "$pkg" == "aria2c" ]] && INSTALL_PKG="aria2"
   [[ "$pkg" == "xz" ]] && INSTALL_PKG="xz-utils"
   printf "[+] %-33s" "Installing $INSTALL_PKG..."
   if apt-get install -y "$INSTALL_PKG" &>/dev/null; then echo "[OK]"; else echo "[FAILED]"; exit 1; fi
  done
 fi
 local BROWSER_FOUND=0
 for path in "${TBB_SEARCH_PATHS[@]}"; do
  if [ -f "$path/Browser/firefox.real" ] || [ -f "$path/firefox" ]; then
   BROWSER_FOUND=1
   break
  fi
 done
 if [ $BROWSER_FOUND -eq 0 ]; then
  install_tor_browser
 fi
}
#-----------------------------------------------------------------------------
# Local Frontend Setup (AriaNg)
#-----------------------------------------------------------------------------
setup_local_gui() {
 mkdir -p "$TEMP_DIR/ariang"
 local GUI_URL="https://github.com/mayswind/AriaNg/releases/download/1.3.7/AriaNg-1.3.7-AllInOne.zip"
 printf "\r[*] %-32s " "Setting up local GUI..."
 if wget -q -O "$TEMP_DIR/ariang/gui.zip" "$GUI_URL"; then
  unzip -q -o "$TEMP_DIR/ariang/gui.zip" -d "$TEMP_DIR/ariang/"
  rm "$TEMP_DIR/ariang/gui.zip"
  echo "[OK]"
 else
  echo "<html><body>Local GUI failed.</body></html>" > "$TEMP_DIR/ariang/index.html"
  echo "[FAILED]"
 fi
 ( ( cd "$TEMP_DIR/ariang" && exec python3 -m http.server $LOCAL_GUI_PORT --bind 127.0.0.1 >/dev/null 2>&1 ) & )
}
#-----------------------------------------------------------------------------
# ASCII Banner
#-----------------------------------------------------------------------------
show_banner() {
 clear
 echo -e "\e[34m"
 echo " ███████╗ █████╗  ███████╗ ████████╗  ████████╗  ██████╗  ██████╗ "
 echo " ██╔════╝██╔══██╗ ██╔════╝ ╚══██╔══╝  ╚══██╔══╝ ██╔═══██╗ ██╔══██╗"
 echo " █████╗  ███████║ ███████╗    ██║        ██║    ██║   ██║ ██████╔╝"
 echo " ██╔══╝  ██╔══██║ ╚════██║    ██║        ██║    ██║   ██║ ██╔══██╗"
 echo " ██║     ██║  ██║ ███████║    ██║        ██║    ╚██████╔╝ ██║  ██║"
 echo " ╚═╝     ╚═╝  ╚═╝ ╚══════╝    ╚═╝        ╚═╝     ╚═════╝  ╚═╝  ╚═╝"
 echo -e "           (C)opyleft Keld Norman - 2026 | v$VERSION\e[0m"
 echo "$LINE"
}
#-----------------------------------------------------------------------------
# Main Execution Start
#-----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then exec sudo "$0" "$@"; fi
show_banner
check_dependencies
#-----------------------------------------------------------------------------
# Resource Prediction Display (Precision Alignment)
#-----------------------------------------------------------------------------
echo "[*] Resource Prediction:"
echo "$LINE"
printf "%-37s%d\n" "[*] Starting Nodes:" "$NUM_INSTANCES"
printf "%-37s%s\n" "[*] Current Storage:" "$STORAGE_TYPE"
printf "%-37s%d / %d MB\n" "[*] Required RAM/Disk:" "$((TOTAL_MEM_REQ / 1024 / 1024))" "$((TOTAL_DISK_REQ / 1024 / 1024))"
echo "$LINE"
printf "%-37s%d Clients\n" "[*] Safe Max (RAM):" "$MAX_SAFE_BY_RAM"
printf "%-37s%d Clients\n" "[*] Safe Max (Disk):" "$MAX_SAFE_BY_DISK"
echo "$LINE"
printf "%-37shttp://127.0.0.1:%d\n" "[+] Dashboard:" "$STATS_PORT"
printf "%-37shttp://127.0.0.1:%d\n" "[+] Local aria2 GUI:" "$LOCAL_GUI_PORT"
printf "%-37shttp://127.0.0.1:%d\n" "[+] aria2 RPC:" "$ARIA2_RPC_PORT"
echo "$LINE"
pkill -9 -f "tor --RunAsDaemon 1" 2>/dev/null
pkill -9 -f "firefox.real|tor-browser|tor-browser-launcher" 2>/dev/null
mkdir -p "$TEMP_DIR/tor" "$TEMP_DIR/browser_home/.config" "$TEMP_DIR/browser_home/.cache" "$TEMP_DIR/xdg_runtime"
setup_local_gui
#-----------------------------------------------------------------------------
# HTML Dashboard Page
#-----------------------------------------------------------------------------
cat <<EOF > "$WELCOME_FILE"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><title>$APP_NAME</title>
<style>
:root { --ms-blue: #0078d4; --ms-neutral: #f3f2f1; }
body { font-family: 'Segoe UI', sans-serif; background: var(--ms-neutral); display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
.card { background: white; padding: 40px; border: 1px solid #edebe9; box-shadow: 0 4px 12px rgba(0,0,0,0.1); width: 650px; }
h1 { border-bottom: 2px solid var(--ms-blue); padding-bottom: 10px; margin-top: 0; }
.btn { color: var(--ms-blue); text-decoration: none; font-weight: bold; border: 2px solid var(--ms-blue); padding: 10px 15px; display: inline-block; margin-top: 20px; }
</style>
</head>
<body><div class="card">
<h1>$APP_NAME Overview v$VERSION</h1>
<p><b>SOCKS rotator:</b> 127.0.0.1:$HAPROXY_PORT | <b>Nodes:</b> $NUM_INSTANCES</p>
<div style="display:flex; gap:15px;">
<a href="http://127.0.0.1:$STATS_PORT" target="_blank" class="btn">HAProxy Overview &#8250;</a>
<a href="http://127.0.0.1:$LOCAL_GUI_PORT/#!/settings/aria2/rpc/protocol/http/host/127.0.0.1/port/$ARIA2_RPC_PORT/interface/jsonrpc" target="_blank" class="btn">aria2 Web Frontend &#8250;</a>
</div>
</div></body></html>
EOF
#-----------------------------------------------------------------------------
# HAProxy & Node Startup
#-----------------------------------------------------------------------------
HAPROXY_CONF="$TEMP_DIR/haproxy.cfg"
cat <<EOF > "$HAPROXY_CONF"
global
    maxconn 10000
    quiet
defaults
    mode tcp
    timeout connect 10s
    timeout client 1h
    timeout server 1h
listen stats
    bind 127.0.0.1:$STATS_PORT
    mode http
    stats enable
    stats uri /
    stats refresh 2s
frontend tor_socks_frontend
    bind 127.0.0.1:$HAPROXY_PORT
    default_backend tor_socks_backends
backend tor_socks_backends
    balance leastconn
EOF
start_node() {
 local i=$1
 local s_port=$((BASE_SOCKS_PORT + i))
 local d_dir="$TEMP_DIR/tor/data$i"
 mkdir -p "$d_dir"
 echo "" > "$d_dir/tor.log"
 tor --RunAsDaemon 1 --SocksPort 127.0.0.1:$s_port --DataDirectory "$d_dir" --PidFile "$d_dir/tor.pid" --Log "notice file $d_dir/tor.log" > /dev/null 2>&1
}
for i in $(seq 1 $NUM_INSTANCES); do
 printf "\r[*] %-32s [%*d/%d]" "Initializing services..." "$PAD" "$i" "$NUM_INSTANCES"
 start_node "$i"
 echo "    server tor$i 127.0.0.1:$((BASE_SOCKS_PORT + i)) check inter 2000 rise 2 fall 3" >> "$HAPROXY_CONF"
done
echo ""
while true; do
 READY_COUNT=$(grep -ls "100%" "$TEMP_DIR"/tor/data*/tor.log | wc -l)
 if [ "$READY_COUNT" -ge "$MIN_READY" ]; then break; fi
 sleep 1
done
haproxy -f "$HAPROXY_CONF" -D -p "$TEMP_DIR/haproxy.pid" -q
#-----------------------------------------------------------------------------
# aria2 Configuration & Startup (Hardened & Firefox Spoofed)
#-----------------------------------------------------------------------------
ARIA_CONF="$TEMP_DIR/aria2.conf"
UA_FIREFOX="Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:144.0) Gecko/20100101 Firefox/144.0"
cat <<EOF > "$ARIA_CONF"
enable-rpc=true
rpc-listen-all=false
rpc-listen-port=$ARIA2_RPC_PORT
rpc-allow-origin-all=true
all-proxy=http://127.0.0.1:$HAPROXY_PORT
proxy-method=get
user-agent=$UA_FIREFOX
check-certificate=false
max-connection-per-server=$NUM_INSTANCES
split=$NUM_INSTANCES
min-split-size=1M
disable-ipv6=true
no-proxy=localhost,127.0.0.1
EOF
sudo -u "$REAL_USER" aria2c --conf-path="$ARIA_CONF" --rpc-listen-all=false --daemon=true >/dev/null 2>&1
#-----------------------------------------------------------------------------
# Browser Setup (Aggressive UI Silencing)
#-----------------------------------------------------------------------------
FOUND_PATH=""
for path in "${TBB_SEARCH_PATHS[@]}"; do
 if [ -f "$path/Browser/firefox.real" ]; then
  FOUND_PATH="$path/Browser/firefox.real"
  break
 elif [ -f "$path/firefox" ]; then
  FOUND_PATH="$path/firefox"
  break
 fi
done
if [ -z "$FOUND_PATH" ]; then
 echo "[!] Error: Tor Browser binary not found."
 cleanup
fi
PROFILE_DIR="$TEMP_DIR/browser_home/profile"
mkdir -p "$PROFILE_DIR"
cat <<EOF > "$PROFILE_DIR/user.js"
user_pref("network.proxy.socks", "127.0.0.1");
user_pref("network.proxy.socks_port", $HAPROXY_PORT);
user_pref("network.proxy.type", 1);
user_pref("network.proxy.no_proxies_on", "localhost, 127.0.0.1");
user_pref("network.proxy.allow_hijacking_localhost", true);
user_pref("browser.startup.homepage", "file://$WELCOME_FILE");
user_pref("security.fileuri.strict_origin_policy", false);
user_pref("browser.translations.enable", false);
user_pref("browser.translations.disabled", true);
user_pref("intl.locale.requested", "en-US");
user_pref("privacy.spoof_english", 2);
user_pref("extensions.torbutton.prompted_language_settings", true);
user_pref("extensions.torbutton.confirm_plugins", false);
user_pref("extensions.torbutton.confirm_set_container", false);
user_pref("privacy.resistFingerprinting", false);
user_pref("privacy.resistFingerprinting.letterboxing", false);
EOF
cp "$PROFILE_DIR/user.js" "$PROFILE_DIR/prefs.js"
chown -R "$REAL_USER":"$REAL_USER" "$TEMP_DIR"
sudo -u "$REAL_USER" env HOME="$TEMP_DIR/browser_home" "$FOUND_PATH" --profile "$PROFILE_DIR" --no-remote --new-instance > /dev/null 2>&1 &
#-----------------------------------------------------------------------------
# Monitoring & Watchdog
#-----------------------------------------------------------------------------
echo "[*] Monitoring Tor clients..."
while true; do
 if ! pgrep -f "$FOUND_PATH.*$TEMP_DIR" > /dev/null; then
  sleep 2
  if ! pgrep -f "$FOUND_PATH.*$TEMP_DIR" > /dev/null; then cleanup; fi
 fi
 T=$(date +%s)
 for i in $(seq 1 $NUM_INSTANCES); do
  LOG="$TEMP_DIR/tor/data$i/tor.log"
  PIDF="$TEMP_DIR/tor/data$i/tor.pid"
  if ! grep -q "Bootstrapped 100%" "$LOG" 2>/dev/null; then
   if [ -f "$LOG" ] && [ $((T - $(stat -c %Y "$LOG"))) -gt 45 ]; then
    [ -f "$PIDF" ] && kill -9 $(cat "$PIDF") 2>/dev/null
    rm -rf "$TEMP_DIR/tor/data$i"
    start_node "$i"
   fi
  fi
 done
 sleep 5
done
#-----------------------------------------------------------------------------
# End of script
#-----------------------------------------------------------------------------
