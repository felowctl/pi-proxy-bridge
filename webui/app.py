#!/usr/bin/env python3

import base64
import hashlib
import json
import os
import re
import secrets
import socket
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

from flask import Flask, jsonify, redirect, render_template, request, session, url_for

app = Flask(__name__)

app.secret_key = secrets.token_hex(32)
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Lax")


WIFI_INTERFACE = "wlan0"
BIND_HOST = "192.168.50.1"
BIND_PORT = 80
HOSTAPD_CONF = Path("/etc/hostapd/hostapd.conf")
XRAY_CONFIG = Path("/usr/local/etc/xray/config.json")
PROXY_LIST_FILE = Path(__file__).resolve().parent / "config.txt"
DNSMASQ_LEASES_FILES = (Path("/var/lib/misc/dnsmasq.leases"), Path("/etc/dnsmasq.leases"))
ADMIN_PASSWORD_FILE = Path(__file__).resolve().parent / "admin_password.hash"
XRAY_SERVICE = "xray"
HOSTAPD_SERVICE = "hostapd"
SUPPORTED_PROXY_PROTOCOLS = ("trojan", "vless")
PROXY_OUTBOUND_TAG = "proxy"
DIRECT_OUTBOUND_TAG = "direct"
CHANNELS_24GHZ = list(range(1, 14))
CHANNELS_5GHZ = [
    36, 40, 44, 48, 52, 56, 60, 64,
    100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144,
    149, 153, 157, 161, 165,
]


def run_cmd(args, timeout=15):
    try:
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result.returncode == 0, result.stdout.strip(), result.stderr.strip()
    except FileNotFoundError as exc:
        return False, "", f"command not found: {exc}"
    except subprocess.TimeoutExpired:
        return False, "", "command timed out"


def systemctl(action, service):
    return run_cmd(["sudo", "systemctl", action, service])


def get_xray_status():
    ok, out, _ = run_cmd(["systemctl", "is-active", XRAY_SERVICE])
    state = out if out else ("active" if ok else "inactive")
    return {"running": state == "active", "state": state}


def get_hotspot_interface():
    try:
        text = read_hostapd_conf()
    except OSError:
        return None
    match = re.search(r"^interface=(.*)$", text, re.MULTILINE)
    return match.group(1).strip() if match else None


def get_bandwidth():
    ok, out, err = run_cmd(["vnstat", "-i", get_hotspot_interface(), "--json"])
    if not ok:
        return {"error": err or "vnstat unavailable"}
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {"error": "could not parse vnstat output"}


def tcp_ping(address, port, timeout=1.5):
    start = time.monotonic()
    try:
        with socket.create_connection((address, port), timeout=timeout):
            pass
        return round((time.monotonic() - start) * 1000, 1)
    except OSError:
        return None


def tcp_ping_targets(targets):
    targets = list(targets)
    if not targets:
        return {}
    with ThreadPoolExecutor(max_workers=min(8, len(targets))) as pool:
        results = list(pool.map(lambda t: tcp_ping(*t), targets))
    return dict(zip(targets, results))


def read_hostapd_conf():
    return HOSTAPD_CONF.read_text()


def get_country_code():
    try:
        text = read_hostapd_conf()
    except OSError:
        return None
    match = re.search(r"^country_code=(.*)$", text, re.MULTILINE)
    return match.group(1).strip().lower() if match else None


def get_hotspot_password():
    try:
        text = read_hostapd_conf()
    except OSError:
        return None
    match = re.search(r"^wpa_passphrase=(.*)$", text, re.MULTILINE)
    return match.group(1).strip() if match else None


def _hash_password(password, salt):
    return hashlib.sha256((salt + password).encode()).hexdigest()


def _write_admin_password_hash(salt, digest):
    ADMIN_PASSWORD_FILE.write_text(f"{salt}:{digest}")
    try:
        os.chmod(ADMIN_PASSWORD_FILE, 0o600)
    except OSError:
        pass


def _read_admin_password_hash():
    try:
        text = ADMIN_PASSWORD_FILE.read_text().strip()
    except OSError:
        return None
    if ":" not in text:
        return None
    return text


def ensure_admin_password_initialized():
    if ADMIN_PASSWORD_FILE.exists():
        return
    seed = "Admin"
    if not seed:
        return
    salt = secrets.token_hex(16)
    _write_admin_password_hash(salt, _hash_password(seed, salt))


def verify_admin_password(password):
    stored = _read_admin_password_hash()
    if not stored:
        return False
    salt, digest = stored.split(":", 1)
    return secrets.compare_digest(_hash_password(password, salt), digest)


def set_admin_password(old_password, new_password):
    if not verify_admin_password(old_password):
        return False, "Current password is incorrect"
    if not (8 <= len(new_password) <= 63):
        return False, "New password must be 8-63 characters"
    salt = secrets.token_hex(16)
    try:
        _write_admin_password_hash(salt, _hash_password(new_password, salt))
    except OSError as exc:
        return False, f"could not save new password: {exc}"
    return True, "Password updated"


def get_hotspot_settings():
    try:
        text = read_hostapd_conf()
    except OSError as exc:
        return {"ssid": "", "channel": 1, "width": "20", "hw_mode": "g", "error": str(exc)}

    ssid_match = re.search(r"^ssid=(.*)$", text, re.MULTILINE)
    channel_match = re.search(r"^channel=(\d+)$", text, re.MULTILINE)
    hw_mode_match = re.search(r"^hw_mode=(.*)$", text, re.MULTILINE)
    ht_capab_match = re.search(r"^ht_capab=(.*)$", text, re.MULTILINE)
    ht_capab_line = ht_capab_match.group(1) if ht_capab_match else ""

    return {
        "ssid": ssid_match.group(1).strip() if ssid_match else "",
        "channel": int(channel_match.group(1)) if channel_match else 1,
        "width": "40" if ("[HT40-]" in ht_capab_line or "[HT40+]" in ht_capab_line) else "20",
        "hw_mode": hw_mode_match.group(1).strip() if hw_mode_match else "g",
    }


def set_hotspot(ssid, password, channel, width):
    if not (1 <= len(ssid) <= 32):
        return False, "SSID must be 1-32 characters"
    if password and not (8 <= len(password) <= 63):
        return False, "WPA2 passphrase must be 8-63 characters"

    if width is not None and width not in ("20", "40"):
        return False, "Width must be 20 or 40"

    try:
        text = read_hostapd_conf()
    except OSError as exc:
        return False, f"could not read hostapd.conf: {exc}"

    hw_mode_match = re.search(r"^hw_mode=(.*)$", text, re.MULTILINE)
    hw_mode = hw_mode_match.group(1).strip() if hw_mode_match else "g"

    if channel is not None:
        valid_channels = CHANNELS_5GHZ if hw_mode == "a" else CHANNELS_24GHZ

        try:
            channel = int(channel)
        except (TypeError, ValueError):
            return False, "Channel must be a number"

        if channel not in valid_channels:
            return False, f"Channel must be one of: {', '.join(map(str, valid_channels))}"

    if re.search(r"^ssid=.*$", text, re.MULTILINE):
        text = re.sub(r"^ssid=.*$", f"ssid={ssid}", text, flags=re.MULTILINE)
    else:
        text += f"\nssid={ssid}\n"

    if password:
        if re.search(r"^wpa_passphrase=.*$", text, re.MULTILINE):
            text = re.sub(
                r"^wpa_passphrase=.*$", f"wpa_passphrase={password}", text, flags=re.MULTILINE
            )
        else:
            text += f"\nwpa_passphrase={password}\n"

    if channel is not None:
        if re.search(r"^channel=.*$", text, re.MULTILINE):
            text = re.sub(r"^channel=.*$", f"channel={channel}", text, flags=re.MULTILINE)
        else:
            text += f"\nchannel={channel}\n"
    else:
        channel_match = re.search(r"^channel=(\d+)$", text, re.MULTILINE)
        channel = int(channel_match.group(1)) if channel_match else 1

    if width is not None:
        if width == "20":
            ht40_token = ""
        elif hw_mode == "a":
            ht40_token = "[HT40+]"
        else:
            ht40_token = "[HT40+]" if channel <= 5 else "[HT40-]"

        def toggle_ht40(match):
            line = re.sub(r"\[HT40[+-]\]", "", match.group(0))
            return line + ht40_token

        if re.search(r"^ht_capab=.*$", text, re.MULTILINE):
            text = re.sub(r"^ht_capab=.*$", toggle_ht40, text, flags=re.MULTILINE)
        elif ht40_token:
            text += f"\nht_capab={ht40_token}\n"

    try:
        HOSTAPD_CONF.write_text(text)
    except OSError as exc:
        return False, f"could not write hostapd.conf: {exc}"

    ok, _, err = systemctl("restart", HOSTAPD_SERVICE)
    if not ok:
        return False, f"hostapd.conf updated but restart failed: {err}"
    return True, "Hotspot settings updated and hostapd restarted"


def get_connected_devices():
    devices = {}
    ok, out, _ = run_cmd(["arp", "-i", get_hotspot_interface(), "-a"])
    if ok:
        for line in out.splitlines():
            arp_match = re.search(r"\(([\d.]+)\)\s+at\s+([0-9a-fA-F:]+)", line)
            if not arp_match:
                continue
            ip, mac = arp_match.group(1), arp_match.group(2).lower()
            if mac == "<incomplete>":
                continue
            devices[mac] = {"mac": mac, "ip": ip, "hostname": ""}

    leases_text = ""
    for leases_file in DNSMASQ_LEASES_FILES:
        try:
            leases_text = leases_file.read_text()
            break
        except OSError:
            continue

    for line in leases_text.splitlines():
        parts = line.split()
        if len(parts) >= 4:
            lease_mac, hostname = parts[1].lower(), parts[3]
            if lease_mac in devices:
                devices[lease_mac]["hostname"] = "" if hostname == "*" else hostname

    return sorted(devices.values(), key=lambda d: (d["ip"], d["mac"]))


def get_wifi_status():
    ok, out, err = run_cmd(["nmcli", "-t", "-f", "DEVICE,STATE,CONNECTION", "device", "status"])
    if not ok:
        return {"state": "unknown", "ssid": None, "error": err or "nmcli unavailable"}
    for line in out.splitlines():
        parts = line.split(":")
        if len(parts) >= 3 and parts[0] == WIFI_INTERFACE:
            return {"state": parts[1], "ssid": parts[2] or None}
    return {"state": "not found", "ssid": None}


def scan_wifi_networks():
    run_cmd(["sudo", "nmcli", "device", "wifi", "rescan", "ifname", WIFI_INTERFACE], timeout=10)
    time.sleep(2)
    ok, out, _ = run_cmd(["nmcli", "-t", "-f", "SSID", "device", "wifi", "list", "ifname", WIFI_INTERFACE])
    if not ok:
        return []
    seen = []
    for line in out.splitlines():
        ssid = line.strip()
        if ssid and ssid not in seen:
            seen.append(ssid)
    return seen


def detect_wifi_channel():
    ok, out, _ = run_cmd(["iw", "dev", WIFI_INTERFACE, "link"])
    if not ok:
        return None
    freq_match = re.search(r"freq:\s*(\d+)", out)
    if not freq_match:
        return None
    freq = int(freq_match.group(1))
    if 2412 <= freq <= 2484:
        return "g", (14 if freq == 2484 else (freq - 2407) // 5)
    if 5180 <= freq <= 5825:
        return "a", (freq - 5000) // 5
    return None


def sync_hotspot_channel_to_wifi():
    detected = detect_wifi_channel()
    if not detected:
        return False, "could not detect wifi channel"
    hw_mode, channel = detected

    try:
        text = read_hostapd_conf()
    except OSError as exc:
        return False, f"could not read hostapd.conf: {exc}"

    text = re.sub(r"^hw_mode=.*$", f"hw_mode={hw_mode}", text, flags=re.MULTILINE)
    text = re.sub(r"^channel=.*$", f"channel={channel}", text, flags=re.MULTILINE)

    has_ieee80211ac = re.search(r"^ieee80211ac=.*$\n?", text, re.MULTILINE)
    if hw_mode == "a":
        if not has_ieee80211ac:
            text = re.sub(r"^ieee80211n=.*$", r"\g<0>\nieee80211ac=1", text, count=1, flags=re.MULTILINE)
    elif has_ieee80211ac:
        text = re.sub(r"^ieee80211ac=.*$\n?", "", text, flags=re.MULTILINE)

    if re.search(r"^ht_capab=.*$", text, re.MULTILINE) and "[HT40" in text:
        if hw_mode == "a":
            ht40_token = "[HT40+]"
        else:
            ht40_token = "[HT40+]" if channel <= 5 else "[HT40-]"
        text = re.sub(
            r"^ht_capab=.*$",
            lambda m: re.sub(r"\[HT40[+-]\]", "", m.group(0)) + ht40_token,
            text,
            flags=re.MULTILINE,
        )

    try:
        HOSTAPD_CONF.write_text(text)
    except OSError as exc:
        return False, f"could not write hostapd.conf: {exc}"

    ok, _, err = systemctl("restart", HOSTAPD_SERVICE)
    if not ok:
        return False, f"hostapd.conf updated but restart failed: {err}"
    return True, f"hotspot channel synced to {channel}"


def connect_wifi(ssid, password):
    if not (1 <= len(ssid) <= 32):
        return False, "SSID must be 1-32 characters"
    if password and not (8 <= len(password) <= 63):
        return False, "WPA2 passphrase must be 8-63 characters"

    run_cmd(["sudo", "nmcli", "device", "wifi", "rescan", "ifname", WIFI_INTERFACE], timeout=10)
    time.sleep(3)

    run_cmd(["sudo", "nmcli", "connection", "delete", ssid], timeout=10)

    cmd = ["sudo", "nmcli", "device", "wifi", "connect", ssid, "ifname", WIFI_INTERFACE]
    if password:
        cmd += ["password", password]

    ok, _, err = run_cmd(cmd, timeout=30)
    if not ok:
        return False, err or f"could not connect {WIFI_INTERFACE} to '{ssid}'"

    if get_hotspot_interface() == "uap0":
        time.sleep(2)
        sync_hotspot_channel_to_wifi()

    return True, f"{WIFI_INTERFACE} connected to '{ssid}'"


def read_xray_config():
    return json.loads(XRAY_CONFIG.read_text())


def find_outbound_by_tag(config, tag):
    for ob in config.get("outbounds", []):
        if ob.get("tag") == tag:
            return ob
    return None


def get_proxy_settings():
    try:
        config = read_xray_config()
    except (OSError, json.JSONDecodeError) as exc:
        return {"error": str(exc)}

    outbound = find_outbound_by_tag(config, PROXY_OUTBOUND_TAG)
    if not outbound:
        return {}

    protocol = outbound.get("protocol")
    sni = outbound.get("streamSettings", {}).get("tlsSettings", {}).get("serverName", "")

    if protocol == "trojan":
        server = (outbound.get("settings", {}).get("servers") or [{}])[0]
        address, port = server.get("address", ""), server.get("port", "")
    elif protocol == "vless":
        vnext = (outbound.get("settings", {}).get("vnext") or [{}])[0]
        address, port = vnext.get("address", ""), vnext.get("port", "")
    else:
        return {"protocol": protocol}

    name = next(
        (
            e["name"]
            for e in get_proxy_list()
            if e["protocol"] == protocol and e["address"] == address and e["port"] == port
        ),
        f"{protocol} ({address})" if address else protocol,
    )

    return {"protocol": protocol, "name": name, "address": address, "port": port, "sni": sni}


def parse_proxy_links(text):
    entries = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        parsed = urlparse(line)
        protocol = parsed.scheme.lower()
        if protocol not in SUPPORTED_PROXY_PROTOCOLS:
            continue
        if not parsed.hostname or not parsed.port:
            continue

        query = parse_qs(parsed.query)
        sni = query.get("sni", [""])[0]
        name = unquote(parsed.fragment) if parsed.fragment else f"{protocol}-{parsed.hostname}"
        secret = unquote(parsed.username) if parsed.username else ""

        entry = {
            "protocol": protocol,
            "name": name,
            "address": parsed.hostname,
            "port": parsed.port,
            "sni": sni,
            "raw": line,
            "key": hashlib.sha256(line.encode()).hexdigest()[:16],
        }
        if protocol == "trojan":
            entry["password"] = secret
        else:  # vless
            entry["id"] = secret
        entries.append(entry)
    return entries


def get_proxy_list():
    if not PROXY_LIST_FILE.exists():
        return []
    try:
        text = PROXY_LIST_FILE.read_text(errors="replace")
    except OSError:
        return []
    return parse_proxy_links(text)


def clear_active_proxy():
    try:
        config = read_xray_config()
    except (OSError, json.JSONDecodeError) as exc:
        return False, f"could not read xray config: {exc}"

    outbounds = config.get("outbounds", [])
    if not any(ob.get("tag") == PROXY_OUTBOUND_TAG for ob in outbounds):
        return True, "no active proxy to clear"

    config["outbounds"] = [ob for ob in outbounds if ob.get("tag") != PROXY_OUTBOUND_TAG]

    try:
        XRAY_CONFIG.write_text(json.dumps(config, indent=2))
    except OSError as exc:
        return False, f"could not write xray config: {exc}"

    ok, _, err = systemctl("restart", XRAY_SERVICE)
    if not ok:
        return False, f"config updated but restart failed: {err}"
    return True, "active proxy cleared"


def import_proxy_list_from_url(url):
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        return False, "URL must start with http:// or https://"

    ok, out, err = run_cmd(["curl", "-fsSL", "--max-time", "10", url], timeout=15)
    if not ok:
        return False, f"could not fetch url: {err or 'curl failed'}"

    text = out.strip()

    if "://" not in text:
        try:
            padded = text + "=" * (-len(text) % 4)
            decoded = base64.b64decode(padded).decode("utf-8", errors="replace")
        except Exception:
            decoded = ""
        if "://" in decoded:
            text = decoded

    if "://" not in text:
        return False, "fetched content doesn't look like a valid config.txt (no trojan:// or vless:// entries)"

    try:
        PROXY_LIST_FILE.write_text(text)
    except OSError as exc:
        return False, f"could not write config.txt: {exc}"

    return True, "config.txt updated from URL"


def apply_proxy_entry(entry):
    try:
        config = read_xray_config()
    except (OSError, json.JSONDecodeError) as exc:
        return False, f"could not read xray config: {exc}"

    outbound = find_outbound_by_tag(config, PROXY_OUTBOUND_TAG)
    if not outbound:
        outbound = {"tag": PROXY_OUTBOUND_TAG}
        config.setdefault("outbounds", []).append(outbound)

    existing_tls = outbound.get("streamSettings", {}).get("tlsSettings", {})
    fingerprint = existing_tls.get("fingerprint", "firefox")

    outbound["protocol"] = entry["protocol"]

    if entry["protocol"] == "trojan":
        outbound["settings"] = {
            "servers": [
                {
                    "address": entry["address"],
                    "port": entry["port"],
                    "password": entry["password"],
                }
            ]
        }
    else:  # vless
        outbound["settings"] = {
            "vnext": [
                {
                    "address": entry["address"],
                    "port": entry["port"],
                    "users": [{"id": entry["id"], "encryption": "none"}],
                }
            ]
        }

    outbound["streamSettings"] = {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
            "serverName": entry.get("sni") or entry["address"],
            "fingerprint": fingerprint,
        },
    }

    try:
        XRAY_CONFIG.write_text(json.dumps(config, indent=2))
    except OSError as exc:
        return False, f"could not write xray config: {exc}"

    ok, _, err = systemctl("restart", XRAY_SERVICE)
    if not ok:
        return False, f"config updated but restart failed: {err}"
    return True, f"Applied '{entry['name']}' and restarted Xray"


def _is_proxy_disable_rule(rule):
    return (
        rule.get("type") == "field"
        and rule.get("outboundTag") == DIRECT_OUTBOUND_TAG
        and rule.get("port") == "0-65535"
        and "domain" not in rule
        and "ip" not in rule
    )


def get_proxy_enabled_status():
    try:
        config = read_xray_config()
    except (OSError, json.JSONDecodeError):
        return False
    rules = config.get("routing", {}).get("rules", [])
    return not any(_is_proxy_disable_rule(rule) for rule in rules)


def set_proxy_enabled(enabled):
    try:
        config = read_xray_config()
    except (OSError, json.JSONDecodeError) as exc:
        return False, f"could not read xray config: {exc}"

    config.setdefault("outbounds", [])
    routing = config.setdefault("routing", {})
    rules = routing.setdefault("rules", [])

    rules[:] = [r for r in rules if not _is_proxy_disable_rule(r)]

    if not enabled:
        if not find_outbound_by_tag(config, DIRECT_OUTBOUND_TAG):
            config["outbounds"].append(
                {"tag": DIRECT_OUTBOUND_TAG, "protocol": "freedom", "settings": {}}
            )
        rules.insert(0, {"type": "field", "port": "0-65535", "outboundTag": DIRECT_OUTBOUND_TAG})

    try:
        XRAY_CONFIG.write_text(json.dumps(config, indent=2))
    except OSError as exc:
        return False, f"could not write xray config: {exc}"

    ok, _, err = systemctl("restart", XRAY_SERVICE)
    if not ok:
        return False, f"config updated but restart failed: {err}"
    return True, ("Proxy enabled" if enabled else "Proxy disabled, all traffic now direct")


def _is_geo_bypass_rule(rule):
    if rule.get("outboundTag") != DIRECT_OUTBOUND_TAG:
        return False
    domain = rule.get("domain") or [""]
    ip = rule.get("ip") or [""]
    return bool(re.match(r"^geosite:category-\w+$", domain[0])) or bool(re.match(r"^geoip:\w+$", ip[0]))


def get_geo_bypass_status():
    try:
        config = read_xray_config()
    except (OSError, json.JSONDecodeError):
        return False
    rules = config.get("routing", {}).get("rules", [])
    return any(_is_geo_bypass_rule(rule) for rule in rules)


def set_geo_bypass(enabled):
    try:
        config = read_xray_config()
    except (OSError, json.JSONDecodeError) as exc:
        return False, f"could not read xray config: {exc}"

    country_code = get_country_code()
    if enabled and not country_code:
        return False, "could not determine country code from hostapd.conf"

    config.setdefault("outbounds", [])
    routing = config.setdefault("routing", {})
    rules = routing.setdefault("rules", [])

    rules[:] = [r for r in rules if not _is_geo_bypass_rule(r)]

    if enabled:
        if not find_outbound_by_tag(config, DIRECT_OUTBOUND_TAG):
            config["outbounds"].append(
                {"tag": DIRECT_OUTBOUND_TAG, "protocol": "freedom", "settings": {}}
            )
        rules.insert(0, {"type": "field", "ip": [f"geoip:{country_code}"], "outboundTag": DIRECT_OUTBOUND_TAG})
        rules.insert(0, {"type": "field", "domain": [f"geosite:category-{country_code}"], "outboundTag": DIRECT_OUTBOUND_TAG})

    try:
        XRAY_CONFIG.write_text(json.dumps(config, indent=2))
    except OSError as exc:
        return False, f"could not write xray config: {exc}"

    ok, _, err = systemctl("restart", XRAY_SERVICE)
    if not ok:
        return False, f"config updated but restart failed: {err}"
    return True, (
        f"{country_code.upper()} sites now bypass the proxy" if enabled else "Geo bypass disabled"
    )



ensure_admin_password_initialized()

PUBLIC_ENDPOINTS = {"login", "static"}


@app.before_request
def require_login():
    if request.endpoint in PUBLIC_ENDPOINTS:
        return None
    if session.get("authenticated"):
        return None
    if request.path.startswith("/api/"):
        return jsonify({"ok": False, "message": "Not authenticated"}), 401
    return redirect(url_for("login"))


@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        password = request.form.get("password", "")
        if verify_admin_password(password):
            session.clear()
            session["authenticated"] = True
            return redirect(url_for("index"))
        error = "Incorrect password"
    return render_template("login.html", error=error)


@app.route("/logout", methods=["POST"])
def logout():
    session.clear()
    return redirect(url_for("login"))



@app.route("/")
def index():
    return render_template(
        "index.html",
        hotspot_interface=get_hotspot_interface(),
        wifi_interface=WIFI_INTERFACE,
        hotspot=get_hotspot_settings(),
        proxy=get_proxy_settings(),
        proxy_enabled=get_proxy_enabled_status(),
        country_code=get_country_code(),
    )


@app.route("/api/status")
def api_status():
    return jsonify(
        {
            "xray": get_xray_status(),
            "bandwidth": get_bandwidth(),
        }
    )


@app.route("/api/hotspot", methods=["POST"])
def api_hotspot():
    ssid = request.form.get("ssid", "").strip()
    password = request.form.get("password", "").strip()
    is_uap0 = get_hotspot_interface() == "uap0"
    channel = None if is_uap0 else request.form.get("channel", "").strip()
    width = None if is_uap0 else request.form.get("width", "").strip()
    ok, message = set_hotspot(ssid, password, channel, width)
    return jsonify({"ok": ok, "message": message}), (200 if ok else 400)


@app.route("/api/devices")
def api_devices():
    return jsonify({"devices": get_connected_devices()})


@app.route("/api/wifi/status")
def api_wifi_status():
    return jsonify(get_wifi_status())


@app.route("/api/wifi/networks")
def api_wifi_networks():
    return jsonify({"networks": scan_wifi_networks()})


@app.route("/api/wifi/connect", methods=["POST"])
def api_wifi_connect():
    ssid = request.form.get("ssid", "").strip()
    password = request.form.get("password", "").strip()
    ok, message = connect_wifi(ssid, password)
    return jsonify({"ok": ok, "message": message}), (200 if ok else 400)


@app.route("/api/proxy/active")
def api_proxy_active():
    return jsonify(get_proxy_settings())


@app.route("/api/proxies")
def api_proxies():
    entries = get_proxy_list()
    pings = tcp_ping_targets((e["address"], e["port"]) for e in entries)
    public = [
        {
            "key": e["key"],
            "name": e["name"],
            "protocol": e["protocol"],
            "ping_ms": pings.get((e["address"], e["port"])),
        }
        for e in entries
    ]
    public.sort(key=lambda e: (e["ping_ms"] is None, e["ping_ms"]))
    return jsonify({"proxies": public})


@app.route("/api/proxies/import", methods=["POST"])
def api_proxies_import():
    url = request.form.get("url", "").strip()
    if not url:
        return jsonify({"ok": False, "message": "URL required"}), 400
    ok, message = import_proxy_list_from_url(url)
    if ok:
        clear_active_proxy()
    return jsonify({"ok": ok, "message": message}), (200 if ok else 400)


@app.route("/api/proxies/delete", methods=["POST"])
def api_proxies_delete():
    try:
        PROXY_LIST_FILE.write_text("")
    except OSError as exc:
        return jsonify({"ok": False, "message": f"could not delete config.txt: {exc}"}), 400
    clear_active_proxy()
    return jsonify({"ok": True, "message": "config.txt cleared"})


@app.route("/api/proxy/apply", methods=["POST"])
def api_proxy_apply():
    key = request.form.get("key", "").strip()
    match = next((e for e in get_proxy_list() if e["key"] == key), None)
    if not match:
        return jsonify({"ok": False, "message": "That proxy is not listed in config.txt"}), 400
    ok, message = apply_proxy_entry(match)
    return jsonify({"ok": ok, "message": message}), (200 if ok else 400)


@app.route("/api/proxy/enabled")
def api_proxy_enabled():
    return jsonify({"enabled": get_proxy_enabled_status()})


@app.route("/api/proxy/enabled/toggle", methods=["POST"])
def api_proxy_enabled_toggle():
    enabled = request.form.get("enabled", "").strip().lower() == "true"
    ok, message = set_proxy_enabled(enabled)
    return jsonify({"ok": ok, "message": message}), (200 if ok else 400)


@app.route("/api/geo/status")
def api_geo_status():
    return jsonify({"enabled": get_geo_bypass_status(), "country_code": get_country_code()})


@app.route("/api/geo/toggle", methods=["POST"])
def api_geo_toggle():
    enabled = request.form.get("enabled", "").strip().lower() == "true"
    ok, message = set_geo_bypass(enabled)
    return jsonify({"ok": ok, "message": message}), (200 if ok else 400)


@app.route("/api/account/password", methods=["POST"])
def api_account_password():
    old_password = request.form.get("old_password", "")
    new_password = request.form.get("new_password", "")
    ok, message = set_admin_password(old_password, new_password)
    if ok:
        session.clear()
    return jsonify({"ok": ok, "message": message}), (200 if ok else 400)


@app.route("/api/reboot", methods=["POST"])
def api_reboot():
    ok, _, err = run_cmd(["sudo", "reboot"])
    return jsonify({"ok": ok, "error": err})


if __name__ == "__main__":
    app.run(host=BIND_HOST, port=BIND_PORT, threaded=True)
