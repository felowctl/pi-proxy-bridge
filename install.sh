#!/bin/bash

# Installation script for pi-proxy-bridge

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root" >&2
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
  echo "Missing required packages. Install them with:"
  echo "  sudo apt install$MISSING_PACKAGES"
  exit 1
fi

systemctl unmask hostapd > /dev/null
systemctl stop hostapd dnsmasq > /dev/null

echo Configuring hostapd

tee /etc/NetworkManager/conf.d/unmanaged.conf > /dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:wlan1
EOF
systemctl restart NetworkManager > /dev/null

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

tee /etc/systemd/system/wlan1-static-ip.service > /dev/null <<EOF
[Unit]
Description=Set static IP for wlan1 (pi-proxy-bridge)
After=sys-subsystem-net-devices-wlan1.device
BindsTo=sys-subsystem-net-devices-wlan1.device

[Service]
Type=oneshot
ExecStart=/sbin/ip addr add 192.168.2.1/24 dev wlan1
ExecStart=/sbin/ip link set wlan1 up

[Install]
WantedBy=multi-user.target
EOF

echo Configuring dnsmasq

tee /etc/dnsmasq.conf > /dev/null <<EOF
interface=wlan1
dhcp-range=192.168.2.10,192.168.2.50,12h
EOF

echo Configuring forwarding

tee /etc/sysctl.d/99-tproxy.conf > /dev/null <<EOF
net.ipv4.ip_forward=1
EOF

# iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE > /dev/null
# iptables -A FORWARD -i wlan1 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT > /dev/null
# iptables -A FORWARD -i wlan0 -o wlan1 -j ACCEPT > /dev/null
# 
# netfilter-persistent save > /dev/null

echo Installing xray

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

read -p "Enter trojan address" TROJAN_ADDRESS
read -p "Enter trojan port" TROJAN_PORT
read -p "Enter trojan password" TROJAN_PASSWORD
read -p "Enter trojan sni" TROJAN_SNI
read -p "Enter trojan fingerprint" TROJAN_FINGERPRINT

sudo tee /usr/local/etc/xray/config.json > /dev/null <<EOF
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
        "network": "tcp,udp",
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


echo Setting up iptables rules

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

netfilter-persistent save > /dev/null


echo Starting services

sysctl --system > /dev/null

systemctl daemon-reload > /dev/null
systemctl enable hostapd dnsmasq xray wlan1-static-ip xray-routing > /dev/null
systemctl start hostapd dnsmasq xray wlan1-static-ip xray-routing > /dev/null