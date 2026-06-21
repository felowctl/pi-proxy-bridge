#!/bin/bash

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root." >&2
  exit 1
fi


step() { echo -e "\n\033[1;34m==> $1\033[0m"; }
ok()   { echo -e "\033[1;32m[OK] $1\033[0m"; }


step "Stopping services"
systemctl disable --now hostapd dnsmasq wlan1-static-ip xray xray-routing || true

step "Removing custom systemd units"
rm -f /etc/systemd/system/wlan1-static-ip.service
rm -f /etc/systemd/system/xray-routing-ip.service
systemctl daemon-reload

step "Removing iptables proxy rules"
iptables -t mangle -D PREROUTING -j XRAY 2>/dev/null || true
iptables -t mangle -F XRAY 2>/dev/null || true
iptables -t mangle -X XRAY 2>/dev/null || true
netfilter-persistent save &>/dev/null || true

step "Removing policy routing"
ip rule del fwmark 1 table 100 2>/dev/null || true
ip route del local default dev lo table 100 2>/dev/null || true

step "Removing config files"
rm -f /etc/sysctl.d/99-tproxy.conf
rm -f /etc/NetworkManager/conf.d/unmanaged.conf
rm -f /etc/dnsmasq.conf
systemctl restart NetworkManager 2>/dev/null || true

echo
ok "Uninstall complete."
echo "Note: hostapd, dnsmasq and xray packages were left installed."