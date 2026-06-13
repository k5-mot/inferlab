#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo: sudo $0 [--restart-docker]" >&2
  exit 1
fi

IFACE="${IFACE:-enp2s0}"
RESTART_DOCKER=0
if [[ "${1:-}" == "--restart-docker" ]]; then
  RESTART_DOCKER=1
fi

if ! command -v ethtool >/dev/null 2>&1; then
  echo "ethtool is required. Install it first: sudo apt install ethtool" >&2
  exit 1
fi

install -d -m 0755 /etc/modprobe.d
cat >/etc/modprobe.d/r8168-stability.conf <<'EOF'
# Stability settings for Realtek RTL8111/8168 using the r8168 DKMS driver.
# These options reduce link drops/resets seen on some boards under load.
options r8168 eee_enable=0 aspm=0 dynamic_aspm=0 s5wol=0
EOF

install -d -m 0755 /etc/NetworkManager/dispatcher.d
cat >/etc/NetworkManager/dispatcher.d/99-disable-eee-enp2s0 <<EOF
#!/bin/sh

IFACE="\$1"
STATE="\$2"

[ "\$IFACE" = "$IFACE" ] || exit 0

case "\$STATE" in
  up|dhcp4-change|connectivity-change)
    /usr/sbin/ethtool --set-eee "$IFACE" eee off >/dev/null 2>&1 || true
    ;;
esac

exit 0
EOF
chmod 0755 /etc/NetworkManager/dispatcher.d/99-disable-eee-enp2s0

install -d -m 0755 /etc/docker
python3 - <<'PY'
import json
from pathlib import Path

path = Path("/etc/docker/daemon.json")
if path.exists() and path.stat().st_size:
    data = json.loads(path.read_text())
else:
    data = {}

data["max-concurrent-downloads"] = 1
data["max-concurrent-uploads"] = 1
data["log-driver"] = "json-file"
log_opts = data.setdefault("log-opts", {})
log_opts["max-size"] = "50m"
log_opts["max-file"] = "3"

if path.exists():
    backup = path.with_suffix(path.suffix + ".bak")
    backup.write_text(path.read_text())

path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY

ethtool --set-eee "$IFACE" eee off || true
ethtool --show-eee "$IFACE" || true

echo "Installed r8168 stability options and NetworkManager EEE dispatcher for $IFACE."
echo "Installed Docker daemon limits. They take effect after Docker is restarted."

if [[ "${RESTART_DOCKER}" -eq 1 ]]; then
  systemctl restart docker
  echo "Docker restarted."
else
  echo "To apply Docker daemon limits now, run: sudo systemctl restart docker"
  echo "The r8168 module options take effect on the next reboot."
fi
