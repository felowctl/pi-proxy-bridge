#!/bin/bash

# Installation script for pi-proxy-bridge

set -e

echo Installing dependencies

sudo apt update > /dev/null
sudo apt install -y hostapd dnsmasq iptables iptables-persistent > /dev/null

sudo systemctl unmask hostapd
sudo systemctl stop hostapd dnsmasq

echo Configuring hostapd

sudo tee /etc/NetworkManager/conf.d/unmanaged.conf > /dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:wlan1
EOF
sudo systemctl restart NetworkManager

sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
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

sudo tee /etc/systemd/system/wlan1-static-ip.service > /dev/null <<EOF
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

sudo tee /etc/dnsmasq.conf > /dev/null <<EOF
interface=wlan1
dhcp-range=192.168.2.10,192.168.2.50,12h
EOF

echo Configuring forwarding

sudo tee /etc/sysctl.d/99-tproxy.conf > /dev/null <<EOF
net.ipv4.ip_forward=1
EOF

sudo iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
sudo iptables -A FORWARD -i wlan1 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i wlan0 -o wlan1 -j ACCEPT

sudo netfilter-persistent save > /dev/null

echo Starting services

sudo sysctl --system > /dev/null

sudo systemctl daemon-reload
sudo systemctl enable hostapd dnsmasq wlan1-static-ip
sudo systemctl start hostapd dnsmasq wlan1-static-ip 