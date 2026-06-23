# Pi Proxy Bridge

Raspberry Pi as a WiFi-to-WiFi hotspot with transparent proxying via Xray.

> Connects to your existing WiFi and creates an access point. Each device that connects to the hotspot gets routed through the proxy. Currently, only the Trojan protocol is supported.

## Prerequisites

- Raspberry Pi with a WiFi module and Raspberry Pi OS Lite 64-bit installed
- Second USB WiFi adapter (optional)

## Installation types

The installer detects your hardware and lets you choose one of the modes:

1. **Virtual interface (uap0)** uses your Pi's existing radio for both the WiFi connection and the hotspot. No extra hardware is needed, but the hotspot shares the same channel/band as your router connection and roughly halves the available bandwidth.
2. **Two separate interfaces (wlan0 + wlan1)** uses a second USB WiFi adapter to create the hotspot. There are no channel or speed restrictions, but it requires extra hardware.

## Installation

```bash
git clone https://github.com/felowctl/pi-proxy-bridge
cd pi-proxy-bridge
chmod +x install.sh
sudo ./install.sh
```

> If using the dual interface mode, see [this hostapd patch](https://github.com/d2r2/upstream-hostapd-force-ht40-mode-patch).

Tested on a Raspberry Pi 4B with a TP-Link Archer TX1U Nano and [this driver](https://github.com/Kiborgik/aic8800dc-linux-patched).

## Demonstration
![Demonstration Gif](demo.gif)