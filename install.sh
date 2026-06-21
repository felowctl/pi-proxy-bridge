#!/bin/bash

# Installation script for pi-proxy-bridge. Requires two separate wifi interfaces

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root." >&2
  exit 1
fi


step() { echo -e "\n\033[1;34m==> $1\033[0m"; }
warn() { echo -e "\033[1;33m[WARN] $1\033[0m"; >&2 }
ok()   { echo -e "\033[1;32m[OK] $1\033[0m"; }


printf "\033[1;34m"
cat <<'EOF'
                                          
 _____ _    _____                    _____     _   _         
|  _  |_|  |  _  |___ ___ _ _ _ _   | __  |___|_|_| |___ ___ 
|   __| |  |   __|  _| . |_'_| | |  | __ -|  _| | . | . | -_|
|__|  |_|  |__|  |_| |___|_,_|_  |  |_____|_| |_|___|_  |___|
                             |___|                  |___|    
EOF
printf "\033[0m"

if ! ip link show wlan0 &> /dev/null; then
  echo 
  warn "wlan0 not found"
  exit 1
fi

if ! ip link show wlan1 &> /dev/null; then
  echo
  warn "wlan1 not found"
  exit 1
fi

REQUIRED_PACKAGES="hostapd dnsmasq iptables iptables-persistent"
MISSING_PACKAGES=""

for pkg in $REQUIRED_PACKAGES; do
  if ! dpkg -s "$pkg" &>/dev/null; then
    MISSING_PACKAGES="$MISSING_PACKAGES $pkg"
  fi
done

if [ -n "$MISSING_PACKAGES" ]; then
  echo
  warn "Missing required packages. Install them with:"
  warn "  sudo apt install$MISSING_PACKAGES"
  exit 1
fi

systemctl unmask hostapd &> /dev/null
systemctl stop hostapd dnsmasq > /dev/null

step "Unmanaging wlan1 in NetworkManager"

tee /etc/NetworkManager/conf.d/unmanaged.conf > /dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:wlan1
EOF
systemctl restart NetworkManager > /dev/null
sleep 5

ok "NetworkManager will no longer manage wlan1"

step "Writing hostapd.conf"

tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
interface=wlan1
driver=nl80211
ssid=PiRouter
hw_mode=g
channel=9
ieee80211d=1
ieee80211n=1
ieee80211ac=1
ieee80211ax=1
wmm_enabled=1
country_code=RU
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=qwerty123
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

ok "hostapd.conf written"

step "Creating static IP systemd service for wlan1"

tee /etc/systemd/system/wlan1-static-ip.service > /dev/null <<EOF
[Unit]
Description=Set static IP for wlan1 (pi-proxy-bridge)
After=sys-subsystem-net-devices-wlan1.device
BindsTo=sys-subsystem-net-devices-wlan1.device

[Service]
Type=oneshot
ExecStart=/sbin/ip addr replace 192.168.2.1/24 dev wlan1
ExecStart=/sbin/ip link set wlan1 up

[Install]
WantedBy=multi-user.target
EOF

ok "Static IP set on wlan1"

step "Writing dnsmasq.conf"

tee /etc/dnsmasq.conf > /dev/null <<EOF
interface=wlan1
dhcp-range=192.168.2.10,192.168.2.50,12h
EOF

ok "dnsmasq.conf written"

step "Enabling IP forwarding"

tee /etc/sysctl.d/99-tproxy.conf > /dev/null <<EOF
net.ipv4.ip_forward=1
EOF
sysctl --system > /dev/null

ok "IP forwarding enabled"

# iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE > /dev/null
# iptables -A FORWARD -i wlan1 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT > /dev/null
# iptables -A FORWARD -i wlan0 -o wlan1 -j ACCEPT > /dev/null
# 
# netfilter-persistent save > /dev/null

step "Starting hostapd and dnsmasq"

systemctl daemon-reload &> /dev/null
systemctl enable hostapd dnsmasq wlan1-static-ip &> /dev/null
systemctl start wlan1-static-ip
sleep 2
systemctl start hostapd dnsmasq &> /dev/null
sleep 2

ok "Hotspot is running"

step "Installing Xray"

if command -v xray &> /dev/null; then
  ok "Xray is already installed ($(xray version | head -1)), skipping install"
else
  bash -c "$(curl --retry 3 --retry-delay 5 --max-time 20 -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  if ! command -v xray &> /dev/null; then
    warn "Xray installation failed"
    exit 1
  fi

  ok "Xray installed successfully"
fi

step "Writing Xray config"

while true; do
  read -rs -p "Paste your trojan:// link: " TROJAN_LINK
  echo
  
  if [[ "$TROJAN_LINK" =~ ^trojan:// ]]; then
    break
  fi

  warn "It is not a valid trojan:// link"
done

LINK_BODY="${TROJAN_LINK#trojan://}"

if [[ "$LINK_BODY" == *"#"* ]]; then
  LINK_BODY="${LINK_BODY%%#*}"
fi

QUERY=""
if [[ "$LINK_BODY" == *"?"* ]]; then
  QUERY="${LINK_BODY#*\?}"
  LINK_BODY="${LINK_BODY%%\?*}"
fi

TROJAN_PASSWORD="${LINK_BODY%%@*}"
HOST_PORT="${LINK_BODY#*@}"
TROJAN_ADDRESS="${HOST_PORT%%:*}"
TROJAN_PORT="${HOST_PORT##*:}"

declare -A PARAMS
if [[ -n "$QUERY" ]]; then
  IFS='&' read -ra PAIRS <<< "$QUERY"
  for pair in "${PAIRS[@]}"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    PARAMS["$key"]="$value"
  done
fi

TROJAN_SNI="${PARAMS[sni]:-$TROJAN_ADDRESS}"
TROJAN_FINGERPRINT="${PARAMS[fp]:-chrome}"

tee /usr/local/etc/xray/config.json > /dev/null <<EOF
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
      "tag": "proxy",
      "protocol": "trojan",
      "settings": {
        "servers": [
          {
            "address": "${TROJAN_ADDRESS}",
            "port": ${TROJAN_PORT},
            "password": "${TROJAN_PASSWORD}"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${TROJAN_SNI}",
          "fingerprint": "${TROJAN_FINGERPRINT}"
        }
      }
    },
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
        "inboundTag": ["tproxy-in"],
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF

systemctl enable xray &> /dev/null
systemctl restart xray &> /dev/null
sleep 2

systemctl is-active --quiet xray && ok "Xray is running" || warn "Xray failed to start"

step "Setting up policy routing for tproxy"

tee "/etc/systemd/system/xray-routing.service" > /dev/null <<EOF
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

systemctl daemon-reload &> /dev/null
systemctl enable xray-routing &> /dev/null
systemctl start xray-routing &> /dev/null
sleep 2

ok "Policy routing applied"

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

netfilter-persistent save &> /dev/null

ok "iptables rules set up"

echo
ok "pi-proxy-bridge installed."
echo
