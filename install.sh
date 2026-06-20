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

systemctl unmask hostapd
systemctl stop hostapd dnsmasq

echo Configuring hostapd

tee /etc/NetworkManager/conf.d/unmanaged.conf > /dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:wlan1
EOF
systemctl restart NetworkManager

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

iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
iptables -A FORWARD -i wlan1 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o wlan1 -j ACCEPT

netfilter-persistent save > /dev/null

echo Starting services

sysctl --system > /dev/null

systemctl daemon-reload
systemctl enable hostapd dnsmasq wlan1-static-ip
systemctl start hostapd dnsmasq wlan1-static-ip 