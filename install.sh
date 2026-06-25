#!/bin/bash

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root." >&2
  exit 1
fi


step() { echo -e "\033[1;34m==> $1\033[0m"; }
warn() { echo -e "\033[1;33m[WARN] $1\033[0m" >&2; }
ok()   { echo -e "\033[1;32m[OK] $1\033[0m"; }


echo -e "\033[1;34m"
cat <<'EOF'                                   
 _____ _    _____                    _____     _   _         
|  _  |_|  |  _  |___ ___ _ _ _ _   | __  |___|_|_| |___ ___ 
|   __| |  |   __|  _| . |_'_| | |  | __ -|  _| | . | . | -_|
|__|  |_|  |__|  |_| |___|_,_|_  |  |_____|_| |_|___|_  |___|
                             |___|                  |___|    
EOF
echo -e "\033[0m"


# ============================================================

REQUIRED_PACKAGES="hostapd dnsmasq iptables iptables-persistent python3-flask"
MISSING_PACKAGES=""

for pkg in $REQUIRED_PACKAGES; do
  if ! dpkg -s "$pkg" &>/dev/null; then
    MISSING_PACKAGES="$MISSING_PACKAGES $pkg"
  fi
done

if [ -n "$MISSING_PACKAGES" ]; then
  warn "Missing required packages. Install them with:"
  warn "  sudo apt install$MISSING_PACKAGES"
  exit 1
fi

if ! ip link show "wlan0" &>/dev/null; then
  warn "wlan0 not found"
  exit 1
fi

# ============================================================

ip link show wlan1 &>/dev/null && WLAN1_FOUND=true || WLAN1_FOUND=false

step "Choose your installation type"
echo

echo -e "  \033[1;32m1)\033[0m Virtual interface (uap0) — single radio"
echo -e "     No extra hardware needed."
echo -e "     Shares your router's channel, ~half bandwidth."
echo

if [ "$WLAN1_FOUND" = false ]; then
  echo -e "  \033[38;5;240m2)\033[0m \033[38;5;240mTwo separate interfaces (wlan0 + wlan1)\033[0m \033[1;31m[wlan1 not found]\033[0m"
  echo -e "     \033[38;5;240mRequires a USB WiFi dongle.\033[0m"
  echo -e "     \033[38;5;240mNo channel/speed restrictions.\033[0m"
else
  echo -e "  \033[1;32m2)\033[0m Two separate interfaces (wlan0 + wlan1)"
  echo -e "     Requires a USB WiFi dongle."
  echo -e "     No channel/speed restrictions."
fi
echo

while true; do
  read -p "$(echo -e '\033[1;33mWhich option do you choose? [1/2] \033[0m')" -r INSTALL_CHOICE

  if [ "$INSTALL_CHOICE" = "1" ]; then
    AP_IFACE="uap0"
    break
  elif [ "$INSTALL_CHOICE" = "2" ]; then
    if [ "$WLAN1_FOUND" = true ]; then
      AP_IFACE="wlan1"
      break
    fi 

    warn "Not available."
  fi
  
  echo
done
echo

# ============================================================

step "Configuration"
echo "Press Enter to accept the default shown in [brackets], or type your own value."
echo

read -p "Hotspot SSID [PiRouter] " -r SSID
read -p "Hotspot password [12345678] " -r WPA_PASSPHRASE
read -p "Country code [US] " -r COUNTRY_CODE
if [ "$AP_IFACE" != "uap0" ]; then
  read -p "Channel [6] " -r CHANNEL
  read -p "Use 5Ghz? [N] " -r

  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    HW_MODE="a"
  fi
fi
echo

SSID="${SSID:-PiRouter}"
WPA_PASSPHRASE="${WPA_PASSPHRASE:-12345678}"
COUNTRY_CODE="${COUNTRY_CODE:-US}"
CHANNEL="${CHANNEL:-6}"
HW_MODE="${HW_MODE:-g}" # g = 2.4Ghz   a = 5Ghz

read -p "Proceed with these settings? [Y/n] " -r
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi
echo

CLIENT_IFACE="wlan0"
HOTSPOT_SUBNET="192.168.50"
AP_IP="$HOTSPOT_SUBNET.1"
DHCP_RANGE_START="$HOTSPOT_SUBNET.10"
DHCP_RANGE_END="$HOTSPOT_SUBNET.50"
XRAY_TPROXY_PORT=12345

# ============================================================

step "Stopping hostapd and dnsmasq"

systemctl unmask hostapd >/dev/null
systemctl stop hostapd dnsmasq >/dev/null

ok "Services stopped."
echo

# ============================================================

step "Unmanaging $AP_IFACE in NetworkManager"

tee /etc/NetworkManager/conf.d/unmanaged.conf >/dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:$AP_IFACE
EOF
systemctl restart NetworkManager >/dev/null
sleep 5

ok "NetworkManager will no longer manage $AP_IFACE."
echo

# ============================================================

if [ "$AP_IFACE" = "uap0" ]; then
  step "Creating virtual AP interface $AP_IFACE"

  if ! iw dev | grep -q "$AP_IFACE"; then
    sudo tee "/etc/systemd/system/$AP_IFACE-create.service" >/dev/null <<EOF
[Unit]
Description=Create virtual AP interface $AP_IFACE (pi-proxy-bridge)
After=sys-subsystem-net-devices-$CLIENT_IFACE.device
Before=hostapd.service
BindsTo=sys-subsystem-net-devices-$CLIENT_IFACE.device

[Service]
Type=oneshot
ExecStart=/sbin/iw dev $CLIENT_IFACE interface add $AP_IFACE type __ap
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload &>/dev/null
    sudo systemctl enable "$AP_IFACE-create.service" &>/dev/null
    sudo systemctl start "$AP_IFACE-create.service" &>/dev/null

    ok "$AP_IFACE created."
  else
    ok "$AP_IFACE already exists."
  fi

  FREQ=$(iw dev "$CLIENT_IFACE" link 2>/dev/null | grep -oP '(?<=freq: )\d+' | head -1)
  if [[ -z "$FREQ" ]]; then
    warn "Could not detect $CLIENT_IFACE's current channel. Connect to your WiFi and re-run this script."
    exit 1
  fi

  if (( FREQ >= 2412 && FREQ <= 2484 )); then
    HW_MODE="g"
    if (( freq == 2484 )); then
      CHANNEL=14
    else
      CHANNEL=$(( (FREQ - 2407) / 5 ))
    fi
  elif (( FREQ >= 5180 && FREQ <= 5825 )); then
    HW_MODE="a"
    CHANNEL=$(( (FREQ - 5000) / 5 ))
  else
    warn "Unknown frequency on $CLIENT_IFACE."
    exit 1
  fi

  ok "Detected $CLIENT_IFACE on channel $CHANNEL. Using the same channel for $AP_IFACE."
fi
echo

# ============================================================

step "Writing hostapd.conf"

if [ "$AP_IFACE" = "wlan1" ]; then
  HT_CAPAB="[HT40+][SHORT-GI-20][SHORT-GI-40][MAX-AMSDU-7935]"
fi

HT_CAPAB="${HT_CAPAB:-[HT40+]}"

IEEE80211AC_LINE=""
if [ "$HW_MODE" = "a" ]; then
  IEEE80211AC_LINE="ieee80211ac=1"
fi

tee /etc/hostapd/hostapd.conf >/dev/null <<EOF
interface=$AP_IFACE
driver=nl80211
ssid=$SSID
hw_mode=$HW_MODE
channel=$CHANNEL
ieee80211d=1
ieee80211n=1
$IEEE80211AC_LINE
ht_capab=$HT_CAPAB
wmm_enabled=1
country_code=$COUNTRY_CODE
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$WPA_PASSPHRASE
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

sed -i '/^$/d' /etc/hostapd/hostapd.conf

ok "hostapd.conf written."
echo

# ============================================================

step "Writing dnsmasq.conf"

tee /etc/dnsmasq.conf >/dev/null <<EOF
interface=$AP_IFACE
dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,12h
EOF

ok "dnsmasq.conf written."
echo

# ============================================================

step "Creating static IP systemd service for $AP_IFACE"

tee "/etc/systemd/system/$AP_IFACE-static-ip.service" >/dev/null <<EOF
[Unit]
Description=Set static IP for $AP_IFACE (pi-proxy-bridge)
After=sys-subsystem-net-devices-$AP_IFACE.device
BindsTo=sys-subsystem-net-devices-$AP_IFACE.device

[Service]
Type=oneshot
ExecStart=/sbin/ip addr replace $AP_IP/24 dev $AP_IFACE
ExecStart=/sbin/ip link set $AP_IFACE up

[Install]
WantedBy=multi-user.target
EOF

ok "Systemd unit created."
echo

# ============================================================

step "Enabling IP forwarding"

tee /etc/sysctl.d/99-tproxy.conf >/dev/null <<EOF
net.ipv4.ip_forward=1
EOF
sysctl --system > /dev/null

ok "IP forwarding enabled."
echo

# ============================================================

# iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE >/dev/null
# iptables -A FORWARD -i wlan1 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT >/dev/null
# iptables -A FORWARD -i wlan0 -o wlan1 -j ACCEPT >/dev/null
# 
# netfilter-persistent save >/dev/null

# ============================================================

step "Starting hostapd and dnsmasq"

systemctl daemon-reload &>/dev/null
systemctl enable hostapd dnsmasq "$AP_IFACE-static-ip" &>/dev/null
systemctl start "$AP_IFACE"-static-ip >/dev/null
sleep 2
systemctl start hostapd dnsmasq >/dev/null
sleep 2

if systemctl is-active --quiet hostapd; then
  ok "hostapd is running."
else
  warn "hostapd failed to start. Debug with: sudo hostapd -dd /etc/hostapd/hostapd.conf"
  warn "Change configuration and re-run this script."
  exit 1
fi
echo

# ============================================================

step "Installing Xray"

if command -v xray &>/dev/null; then
  ok "Xray is already installed ($(xray version | head -1 | awk '{print $2}')), skipping install."
else
  bash -c "$(curl --retry 3 --retry-delay 5 --max-time 20 -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  if ! command -v xray &>/dev/null; then
    warn "Xray installation failed. Try installing it with:"
    warn '  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install'
    exit 1
  fi

  ok "Xray installed successfully."
fi
echo

# ============================================================

step "Writing Xray config"

tee /usr/local/etc/xray/config.json >/dev/null <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "tproxy-in",
      "port": 12345,
      "protocol": "tunnel",
      "settings": {
        "allowedNetwork": "tcp,udp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "port": "0-65535",
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "inboundTag": ["tproxy-in"],
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF

systemctl enable xray &>/dev/null
systemctl restart xray &>/dev/null
sleep 2

systemctl is-active --quiet xray && ok "Xray is running." || warn "Xray failed to start."
echo

# ============================================================

step "Setting up policy routing for Xray"

tee "/etc/systemd/system/xray-routing.service" >/dev/null <<EOF
[Unit]
Description=Xray TProxy policy routing (pi-proxy-bridge)
After=network.target
 
[Service]
Type=oneshot
ExecStart=/sbin/ip route add local default dev lo table 100
ExecStart=/sbin/ip rule add fwmark 1 table 100
RemainAfterExit=yes
 
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload &>/dev/null
systemctl enable xray-routing &>/dev/null
systemctl start xray-routing &>/dev/null
sleep 2

if systemctl is-active --quiet xray-routing; then
  ok "Policy routing applied."
else
  warn "Policy routing didn't apply."
  exit 1
fi
echo

# ============================================================

step "Downloading xray-knife"

curl --retry 3 --retry-delay 5 --max-time 20 -fsSL https://github.com/lilendian0x00/xray-knife/releases/latest/download/Xray-knife-linux-arm64-v8a.zip -o xray-knife
unzip xray-knife
cd Xray-knife-linux
chmod +x xray-knife
mv xray-knife /usr/local/bin/xray-knife

ok "Xray-knife installed."

# ============================================================

step "Setting up iptables rules"

iptables -t mangle -D PREROUTING -j XRAY 2>/dev/null || true
iptables -t mangle -F XRAY 2>/dev/null || true
iptables -t mangle -X XRAY 2>/dev/null || true
iptables -t mangle -N XRAY
iptables -t mangle -A XRAY -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A XRAY -d 100.64.0.0/10 -j RETURN
iptables -t mangle -A XRAY -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A XRAY -d 169.254.0.0/16 -j RETURN
iptables -t mangle -A XRAY -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A XRAY -d 192.0.0.0/24 -j RETURN
iptables -t mangle -A XRAY -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A XRAY -d 240.0.0.0/4 -j RETURN
iptables -t mangle -A XRAY -d 255.255.255.255/32 -j RETURN
iptables -t mangle -A XRAY -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A XRAY -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
iptables -t mangle -A XRAY -p udp -j TPROXY --on-port 12345 --tproxy-mark 1
iptables -t mangle -A PREROUTING -j XRAY

netfilter-persistent save &>/dev/null

ok "iptables rules set up."
echo

# ============================================================

step "Setting up Web UI"
cp -r ./webui /opt/
tee "/etc/systemd/system/webui.service" >/dev/null <<EOF
[Unit]
Description=PiRouter Web UI (pi-proxy-bridge)
After=network.target hostapd.service xray.service
 
[Service]
Type=simple
User=root
WorkingDirectory=/opt/webui
ExecStart=/usr/bin/python3 /opt/webui/app.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable webui &>/dev/null
systemctl start webui
ok "Web UI is ready and can be accessed on http://$AP_IP"
echo

# ============================================================

ok "pi-proxy-bridge installed."
echo
