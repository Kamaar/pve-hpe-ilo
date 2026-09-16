# Changelog

## 1.1.1 — 2026-09-16

**Anyone on 1.1.0 should update: notifications did not actually deliver.**

Everything below was found by running `pve-hpe-ilo check --force` on real
hardware for the first time. All of it passed the offline tests; none of it
survived contact with an actual send.

- **The template did not exist.** PVE 9.2.20 ships templates only for fencing,
  package-updates, replication, test and vzdump — the `simple` one this asked
  for is not among them, and there is no generic template to borrow. The
  package now brings its own and installs it to
  `/etc/pve/notification-templates/default`, which PVE resolves before its own
  directory, and which survives upgrades and reaches every node in a cluster.
- **Failures were reported as successes.** `PVE::Notify` does not die when a
  target fails; it prints the error to stderr and returns normally, so the
  absence of an exception meant nothing. An alerting path that claims success
  when it failed is worse than one that fails loudly. The call now captures
  stderr and reads it, and a failure degrades to the journal with the CLI
  saying so.
- **`install.sh` aborted partway.** `/etc/pve` is pmxcfs, which owns its own
  permissions and refuses chmod, so `install -m` failed there — and under
  `set -e` that silently skipped the hooks, the daemon restarts and enabling
  the timer. The template step now uses `cp` and can no longer abort the run.
- The two summary-banner console flags are separated:
  `summaryOverrideInstalled` means the override is registered,
  `summaryInjected` means a banner has been placed. The second is false until
  a Summary page has been opened, which is not a fault.
- The CLI printed `0 spare(s)` where the controller reports the field as null.
  iLO 4 on a Gen9 exposes neither `SparePhysicalDriveCount` nor
  `UnassignedPhysicalDriveCount` nor `RebuildPriority`; absent is now shown as
  absent.

## 1.1.0 — 2026-09-16

The panel stops being something you have to remember to look at.

### Health banner

A banner at the top of the Hardware tab summarises every check, and a second
one appears on the **node Summary page** — the page everyone actually lands on
— whenever something is wrong. It stays invisible while the hardware is
healthy: a permanent green strip on every node's summary is noise, and noise is
what people learn to look past.

Checks cover sensor thresholds, fans pinned near maximum, power supply health,
controller and array health, the cache backup capacitor, drives approaching
their trip temperature, and any drive that has begun reallocating sectors.

### Notifications

The same evaluation runs on a timer every fifteen minutes and notifies through
Proxmox's own notification system, so alerts arrive wherever backup mail
already goes, with no separate mail configuration.

It notifies on **change**, not on state. A drive that has been at three
reallocated sectors for a month says so once, not ninety-six times a day.

```sh
pve-hpe-ilo check --dry-run    # show what it would send, change nothing
pve-hpe-ilo check --force      # send anyway, to test the path
systemctl disable --now pve-hpe-ilo-check.timer
```

`PVE::Notify` is not a supported public API, so the call is wrapped: if Proxmox
changes it, the message goes to the journal rather than vanishing.

### Bars now agree with the checks

The coloured bars were shaded by percentage of their maximum, while the checks
fire on the actual threshold. A sensor at 50 °C against a 60 °C limit is 83% of
the way there, so the bar went amber while the banner — correctly — stayed
green. A panel that contradicts itself teaches people to ignore both halves.

Bars now take the same thresholds the checks use. This also fixes a rebuild at
95% being drawn in red, as though a nearly finished rebuild were an emergency.

### Also

Two fields that were collected and never shown: spare and unassigned drive
counts, and power supply capacity with the percentage currently drawn.

## 1.0.1 — 2026-09-15

Fixes found by running 1.0.0 on real hardware. No new features.

### Locate LED

The icon reverted a few seconds after being clicked. The panel reloads from
the cache every five seconds and the cache carries iLO's `IndicatorLED`, which
is only re-read on the storage cycle up to five minutes later — so the click
looked like it had failed, at the moment you most need to trust it. The panel
now holds the state it asked for until iLO confirms it, then stops overriding.

The button itself shows the state as well, not only the status column beside
it, and `Lit` counts as on alongside `Blinking`: firmware differs on whether a
located bay blinks or holds steady.

### Updating

`install.sh` now always restarts `pvedaemon` and `pveproxy`, instead of leaving
it to the patcher, which only restarted them when it had changed a hook. On an
update the hooks are already in place, so nothing was restarted and both
daemons went on serving the previous version out of cache. The patcher gains
`--no-restart` so the two do not both do it.

`install.sh` also prints the version it is installing and the one it replaces.
Running it from a stale checkout silently downgrades a node, and the symptom —
a feature that worked a minute ago and now does not — points nowhere near the
cause.

### Documentation

`INSTALL.md` now describes updating by `git pull` rather than copying files,
what to do when the directory is a manual copy rather than a clone, and the
four commands that expose a half-updated install. Copying a subset of files
never fails loudly: it leaves a node running a new CLI against an old poller,
which reports itself healthy.

## 1.0.0 — 2026-09-15

First release. Running on a DL380 Gen9 / iLO 4 2.82 under Proxmox VE 9.2.18.

### Panel

A "Hardware (iLO)" tab on the node view, showing:

- **Temperatures** for every populated sensor, with a bar scaled to the
  sensor's own critical threshold
- **Fan speeds**, as duty cycle on iLO 4 or RPM where the firmware reports it
- **Power** draw, with the 20-minute min/average/max window and per-bay PSU
  output and input voltage
- **Smart Array** controller state — operating mode, cache size, cache backup
  power, rebuild priority — plus logical drives with any rebuild in progress,
  and physical drives with bay, model, capacity, temperature, run time and
  grown defect count
- A **locate LED** control per bay, for identifying a disk before pulling it

### How it attaches

Proxmox VE has no plugin API for its web interface, so two upstream files get
one line each: a guarded `require` in `PVE/API2/Nodes.pm` that registers the
API path, and a `<script>` tag in `index.html.tpl`. `pvemanagerlib.js` is never
modified — the tab is grafted on with an ExtJS override. An apt hook reapplies
both after every upgrade, since either package replaces them.

### Data sources

Redfish over the network is the primary source. Where iLO reports nothing —
drive temperatures and run time are empty with third-party disks in HP
carriers — `smartctl -d cciss,N` fills the gaps through the controller
passthrough, joined by serial number because the cciss index order does not
follow bay order. The locate LED uses `ssacli` when it is installed, and the
control is hidden when it is not.

The collector is core Perl plus `JSON`, all present on a stock node.
smartmontools ships with Proxmox. Nothing else is pulled onto the hypervisor.

### Reliability

The poller is a separate daemon from the API handler because iLO 4 needs one
to three seconds per Redfish call: the endpoint reads a cache file and never
talks to the BMC. The Smart Array walk costs one request per drive and runs on
its own 300-second cycle, carrying its last good result forward.

### Tested

108 offline tests: the Redfish mapping and its iLO 4 / iLO 5 differences, the
smartctl parsing and serial-number merge, the argument validation on the only
write path, and the patcher driven against stand-in copies of the two Proxmox
files through a simulated upgrade.

### Known limits

- Fan control is not possible: the BMC owns the fan curve and HPE exposes no
  supported way to set it.
- RAID configuration is out of scope. iLO 4's `SmartStorage` is read-only and
  the writable `SmartStorageConfig` resource is Gen10+.
- Old iLO 4 firmware typed `#ComputerSystem.1.0.1` has no
  `Oem.Hp.AggregateHealthStatus`, so per-subsystem health badges are
  unavailable there.
- The iLO 5/6 mapping is written from HPE's schema documentation and covered by
  tests, but has not been exercised against real Gen10 hardware.
