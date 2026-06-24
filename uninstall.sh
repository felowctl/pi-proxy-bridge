#!/bin/bash

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root." >&2
  exit 1
fi

step() { echo -e "\033[1;34m==> $1\033[0m"; }
warn() { echo -e "\033[1;33m[WARN] $1\033[0m" >&2; }
ok()   { echo -e "\033[1;32m[OK] $1\033[0m"; }

if [ -f /etc/systemd/system/uap0-static-ip.service ]; then
  AP_IFACE="uap0"
elif [ -f /etc/systemd/system/wlan1-static-ip.service ]; then
  AP_IFACE="wlan1"
else
  AP_IFACE=""
  warn "Could not determine which AP interface was used (uap0 or wlan1)."
  warn "Static-IP service cleanup for that interface will be skipped."
fi

if [ -n "$AP_IFACE" ]; then
  ok "Detected AP interface: $AP_IFACE"
fi
echo

step "Stopping services"

systemctl disable --now hostapd dnsmasq xray xray-routing webui &>/dev/null || true

if [ -n "$AP_IFACE" ]; then
  systemctl disable --now "${AP_IFACE}-static-ip" &>/dev/null || true
fi

ok "Services stopped."
echo

step "Removing systemd units"

rm -f /etc/systemd/system/wlan1-static-ip.service
rm -f /etc/systemd/system/uap0-static-ip.service
rm -f /etc/systemd/system/xray-routing.service
rm -f /etc/systemd/system/webui.service
systemctl daemon-reload &>/dev/null

ok "Systemd units removed."
echo

if iw dev 2>/dev/null | grep -q "uap0"; then
  step "Removing virtual interface uap0"
  iw dev uap0 del &>/dev/null || warn "Could not remove uap0 (it may already be gone)."
  ok "uap0 removed."
  echo
fi

step "Restoring NetworkManager"

rm -f /etc/NetworkManager/conf.d/unmanaged.conf
systemctl restart NetworkManager &>/dev/null || true

ok "NetworkManager will manage all interfaces again."
echo

step "Removing config files"

rm -f /etc/hostapd/hostapd.conf
rm -f /etc/dnsmasq.conf
rm -f /etc/sysctl.d/99-tproxy.conf
sysctl --system &>/dev/null || true

ok "Config files removed."
echo

step "Removing iptables rules"

iptables -t mangle -D PREROUTING -j XRAY 2>/dev/null || true
iptables -t mangle -F XRAY 2>/dev/null || true
iptables -t mangle -X XRAY 2>/dev/null || true

if command -v netfilter-persistent &>/dev/null; then
  netfilter-persistent save &>/dev/null || true
fi

ok "iptables rules removed."
echo

step "Removing policy routing"

ip rule del fwmark 1 table 100 2>/dev/null || true
ip route del local default dev lo table 100 2>/dev/null || true

ok "Policy routing removed."
echo

step "Removing Xray config"

rm -f /usr/local/etc/xray/config.json

ok "Xray config removed."
echo

ok "pi-proxy-bridge uninstalled."
echo
echo "Note: the following were intentionally left installed:"
echo "  - hostapd, dnsmasq, iptables-persistent (apt packages)"
echo "  - the xray binary itself"
echo
echo "Remove them manually if you don't need them anymore:"
echo "  sudo apt remove hostapd dnsmasq iptables-persistent"
echo "  sudo bash -c \"\$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ remove"
echo