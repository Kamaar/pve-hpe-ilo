#!/bin/bash
#
# Exercises scripts/pve-hpe-ilo-patch against stand-in copies of the two
# Proxmox files, including the case that matters most: an upgrade replacing
# them with pristine versions and the apt hook putting the patch back.
#
# Run: bash t/patch.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCHER="$HERE/../scripts/pve-hpe-ilo-patch"
ROOT="$(mktemp -d)"
export PVE_HPE_ILO_ROOT="$ROOT"

PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    echo "ok $((PASS + FAIL)) - $1"
}

nok() {
    FAIL=$((FAIL + 1))
    echo "not ok $((PASS + FAIL)) - $1"
}

check() {
    if [ "$1" -eq 0 ]; then ok "$2"; else nok "$2"; fi
}

cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

NODES_PM="$ROOT/usr/share/perl5/PVE/API2/Nodes.pm"
INDEX_TPL="$ROOT/usr/share/pve-manager/index.html.tpl"

install_pristine() {
    mkdir -p "$(dirname "$NODES_PM")" "$(dirname "$INDEX_TPL")"

    cat > "$NODES_PM" <<'PM'
package PVE::API2::Nodes;

use strict;
use warnings;

package PVE::API2::Nodes::Nodeinfo;

sub something { return 1; }

package PVE::API2::Nodes;

__PACKAGE__->register_method({ name => 'index' });

1;
PM

    cat > "$INDEX_TPL" <<'TPL'
<!DOCTYPE html>
<html>
<head>
<script type="text/javascript" src="/pve2/ext6/ext-all.js"></script>
<script type="text/javascript" src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>
</head>
<body></body>
</html>
TPL
}

install_pristine

# --- apply -----------------------------------------------------------------

"$PATCHER" --quiet
check $? "apply exits cleanly"

grep -q 'PVE::HPEiLO::API::register' "$NODES_PM"
check $? "API hook inserted into Nodes.pm"

perl -c "$NODES_PM" >/dev/null 2>&1
check $? "patched Nodes.pm still compiles"

tail -2 "$NODES_PM" | grep -q '^1;'
check $? "trailing 1; is still the last statement"

grep -q 'pve-hpe-ilo.js?ver=\[% version %\]' "$INDEX_TPL"
check $? "script tag inserted with the upstream cache-busting query"

grep -A1 'pvemanagerlib.js' "$INDEX_TPL" | grep -q 'pve-hpe-ilo.js'
check $? "script tag comes after pvemanagerlib.js"

# --- idempotence -----------------------------------------------------------

"$PATCHER" --quiet
[ "$(grep -c 'PVE::HPEiLO::API::register' "$NODES_PM")" -eq 1 ]
check $? "re-running does not duplicate the API hook"

[ "$(grep -c 'pve-hpe-ilo.js' "$INDEX_TPL")" -eq 1 ]
check $? "re-running does not duplicate the script tag"

# --- check mode ------------------------------------------------------------

"$PATCHER" --check --quiet >/dev/null 2>&1
check $? "--check passes while patched"

# --- the upgrade cycle -----------------------------------------------------

install_pristine   # simulates apt replacing both files

"$PATCHER" --check --quiet >/dev/null 2>&1
[ $? -ne 0 ]
check $? "--check fails after an upgrade wipes the hooks"

"$PATCHER" --quiet
grep -q 'PVE::HPEiLO::API::register' "$NODES_PM" && grep -q 'pve-hpe-ilo.js' "$INDEX_TPL"
check $? "apply restores both hooks after an upgrade"

# --- removal ---------------------------------------------------------------

"$PATCHER" --remove --quiet
! grep -q 'pve-hpe-ilo' "$NODES_PM" && ! grep -q 'pve-hpe-ilo' "$INDEX_TPL"
check $? "--remove strips both hooks"

perl -c "$NODES_PM" >/dev/null 2>&1
check $? "Nodes.pm compiles after removal"

# Removal without a backup must still work: delete the saved originals first.
"$PATCHER" --quiet
rm -rf "$ROOT/var/lib/pve-hpe-ilo/backup"
"$PATCHER" --remove --quiet
! grep -q 'pve-hpe-ilo' "$NODES_PM" && ! grep -q 'pve-hpe-ilo' "$INDEX_TPL"
check $? "--remove works with no backup available"

perl -c "$NODES_PM" >/dev/null 2>&1
check $? "in-place removal leaves valid Perl"

echo "1..$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
