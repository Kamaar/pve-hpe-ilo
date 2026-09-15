#!/bin/bash
#
# Installs pve-hpe-ilo on a Proxmox VE node. Run as root from the repo root.
#
#   ./install.sh            install or update
#   ./install.sh --uninstall remove everything except the config file

set -e

SRC="$(cd "$(dirname "$0")" && pwd)"

PERL_DIR="/usr/share/perl5/PVE/HPEiLO"
JS_DIR="/usr/share/pve-manager/js"
CONF_DIR="/etc/pve-hpe-ilo"
UNIT="/etc/systemd/system/pve-hpe-ilo.service"
APT_HOOK="/etc/apt/apt.conf.d/99-pve-hpe-ilo"

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi

if [ ! -d /usr/share/pve-manager ]; then
    echo "/usr/share/pve-manager not found - this is not a Proxmox VE node" >&2
    exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
    echo "removing hooks from the Proxmox files..."
    /usr/sbin/pve-hpe-ilo-patch --remove || true

    systemctl disable --now pve-hpe-ilo.service 2>/dev/null || true

    rm -f "$UNIT" "$APT_HOOK"
    rm -f /usr/sbin/pve-hpe-ilo /usr/sbin/pve-hpe-ilo-poller /usr/sbin/pve-hpe-ilo-patch
    rm -f "$JS_DIR/pve-hpe-ilo.js"
    rm -rf "$PERL_DIR" /var/lib/pve-hpe-ilo

    systemctl daemon-reload
    echo "done. $CONF_DIR was left in place; remove it by hand if you want the credentials gone."
    exit 0
fi

echo "installing Perl modules to $PERL_DIR"
install -d -m 0755 "$PERL_DIR"
# Installed as a set rather than named one by one, so adding a module never
# means remembering to edit this script.
for module in "$SRC"/perl/PVE/HPEiLO/*.pm; do
    install -m 0644 "$module" "$PERL_DIR/"
done

echo "installing executables to /usr/sbin"
install -m 0755 "$SRC/sbin/pve-hpe-ilo"           /usr/sbin/pve-hpe-ilo
install -m 0755 "$SRC/sbin/pve-hpe-ilo-poller"    /usr/sbin/pve-hpe-ilo-poller
install -m 0755 "$SRC/scripts/pve-hpe-ilo-patch"  /usr/sbin/pve-hpe-ilo-patch

echo "installing the panel to $JS_DIR"
install -m 0644 "$SRC/js/pve-hpe-ilo.js" "$JS_DIR/pve-hpe-ilo.js"

echo "installing the systemd unit and apt hook"
install -m 0644 "$SRC/etc/systemd/pve-hpe-ilo.service" "$UNIT"
install -m 0644 "$SRC/etc/apt/99-pve-hpe-ilo" "$APT_HOOK"

install -d -m 0700 "$CONF_DIR"
if [ ! -f "$CONF_DIR/config.json" ]; then
    install -m 0600 "$SRC/etc/config.example.json" "$CONF_DIR/config.json"
    NEW_CONFIG=1
else
    echo "keeping the existing $CONF_DIR/config.json"
    NEW_CONFIG=0
fi

echo "patching the Proxmox files"
/usr/sbin/pve-hpe-ilo-patch

systemctl daemon-reload

if [ "$NEW_CONFIG" -eq 1 ]; then
    cat <<EOF

Installed. The service is NOT started yet, because the config file still holds
the example credentials.

  1. edit $CONF_DIR/config.json   (host, username, password)
  2. pve-hpe-ilo probe                     # verify iLO answers
  3. systemctl enable --now pve-hpe-ilo    # start sampling

Then reload the Proxmox GUI with a hard refresh (Ctrl-Shift-R) and open
any node: a "Hardware (iLO)" tab appears in the left-hand list.
EOF
else
    systemctl enable pve-hpe-ilo.service
    systemctl restart pve-hpe-ilo.service
    echo
    echo "Installed and restarted. Hard-refresh the GUI (Ctrl-Shift-R)."
fi
