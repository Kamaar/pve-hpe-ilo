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
UNIT_DIR="/etc/systemd/system"
APT_HOOK="/etc/apt/apt.conf.d/99-pve-hpe-ilo"
TEMPLATE_DIR="/etc/pve/notification-templates/default"

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

    systemctl disable --now pve-hpe-ilo-check.timer 2>/dev/null || true
    systemctl disable --now pve-hpe-ilo.service 2>/dev/null || true

    rm -f "$UNIT_DIR/pve-hpe-ilo.service" \
	  "$UNIT_DIR/pve-hpe-ilo-check.service" \
	  "$UNIT_DIR/pve-hpe-ilo-check.timer" \
	  "$APT_HOOK"
    rm -f "$TEMPLATE_DIR"/pve-hpe-ilo-*.hbs
    rm -f /usr/sbin/pve-hpe-ilo /usr/sbin/pve-hpe-ilo-poller /usr/sbin/pve-hpe-ilo-patch
    rm -f "$JS_DIR/pve-hpe-ilo.js"
    rm -rf "$PERL_DIR" /var/lib/pve-hpe-ilo

    systemctl daemon-reload
    echo "done. $CONF_DIR was left in place; remove it by hand if you want the credentials gone."
    exit 0
fi

# Announce which tree is being installed. Running an old checkout by mistake
# silently downgrades a node, and the symptom -- a feature that was working and
# now is not -- points nowhere near the cause.
SRC_VERSION=$(sed -n "s/^our \$VERSION = '\(.*\)';/\1/p" \
    "$SRC/perl/PVE/HPEiLO/Version.pm" 2>/dev/null)
INSTALLED_VERSION=$(/usr/sbin/pve-hpe-ilo version 2>/dev/null | awk '{print $2}')

echo "installing pve-hpe-ilo ${SRC_VERSION:-unknown} from $SRC"
if [ -n "$INSTALLED_VERSION" ] && [ -n "$SRC_VERSION" ] \
	&& [ "$INSTALLED_VERSION" != "$SRC_VERSION" ]; then
    echo "  (replacing $INSTALLED_VERSION already on this node)"
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

echo "installing the systemd units and apt hook"
for unit in "$SRC"/etc/systemd/*.service "$SRC"/etc/systemd/*.timer; do
    install -m 0644 "$unit" "$UNIT_DIR/"
done
install -m 0644 "$SRC/etc/apt/99-pve-hpe-ilo" "$APT_HOOK"

# Notification templates. PVE resolves a template name against this override
# directory before its own, and ships no generic one to borrow -- 9.2.20 has
# templates only for fencing, package-updates, replication, test and vzdump.
# They live under /etc/pve so they survive upgrades and reach every node.
if [ -d /etc/pve ]; then
    echo "installing the notification template to $TEMPLATE_DIR"
    install -d -m 0755 "$TEMPLATE_DIR"
    install -m 0644 "$SRC"/etc/notification-templates/*.hbs "$TEMPLATE_DIR/"
else
    echo "WARNING: /etc/pve is not mounted; notification template not installed" >&2
fi

install -d -m 0700 "$CONF_DIR"
if [ ! -f "$CONF_DIR/config.json" ]; then
    install -m 0600 "$SRC/etc/config.example.json" "$CONF_DIR/config.json"
    NEW_CONFIG=1
else
    echo "keeping the existing $CONF_DIR/config.json"
    NEW_CONFIG=0
fi

echo "patching the Proxmox files"
/usr/sbin/pve-hpe-ilo-patch --no-restart

systemctl daemon-reload

# Always, not only when the patcher changed something. pvedaemon caches the
# Perl modules it has loaded and pveproxy caches the rendered index page, so
# after an update that changed API.pm or the panel they would both go on
# serving the previous version indefinitely.
echo "restarting pvedaemon and pveproxy"
systemctl restart pvedaemon pveproxy

if [ "$NEW_CONFIG" -eq 1 ]; then
    cat <<EOF

Installed. The service is NOT started yet, because the config file still holds
the example credentials.

  1. edit $CONF_DIR/config.json   (host, username, password)
  2. pve-hpe-ilo probe                          # verify iLO answers
  3. systemctl enable --now pve-hpe-ilo         # start sampling
  4. systemctl enable --now pve-hpe-ilo-check.timer   # notify on changes

Then reload the Proxmox GUI with a hard refresh (Ctrl-Shift-R) and open
any node: a "Hardware (iLO)" tab appears in the left-hand list.
EOF
else
    systemctl enable pve-hpe-ilo.service
    systemctl restart pve-hpe-ilo.service

    # Enabled only where the poller is already configured, so a fresh install
    # cannot mail about a machine that has not been set up yet.
    systemctl enable --now pve-hpe-ilo-check.timer
    echo
    echo "Installed and restarted. Hard-refresh the GUI (Ctrl-Shift-R)."
    echo "Hardware checks run every 15 minutes; 'systemctl disable --now"
    echo "pve-hpe-ilo-check.timer' turns the notifications off."
fi
