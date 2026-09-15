# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`pve-hpe-ilo` adds a "Hardware (iLO)" tab to the Proxmox VE web interface,
showing temperatures, fan speeds, power draw and Smart Array RAID state read
from an HPE ProLiant's iLO over Redfish. Target hardware is a **DL380 Gen9 with
iLO 4**; iLO 5/6 is also handled.

Development happens on Windows (`Z:\repo\proxmox`), deployment on a Debian-based
Proxmox node. Everything here runs on Linux — `.gitattributes` forces LF, and a
CRLF checkout breaks every shebang.

## Commands

```sh
make test            # normalization tests + patcher tests; no Proxmox node needed
make syntax          # perl -c / bash -n / node --check across the tree
perl -I perl t/normalize.t     # a single test file
bash t/patch.sh                # ditto

make check           # on the node only: hooks present, service up, sample fresh
```

There is no build step. `./install.sh` copies files into place on a node;
`./install.sh --uninstall` reverses it.

`perl -c` on `perl/PVE/HPEiLO/API.pm` only works on an actual node — it calls
into `PVE::API2::Nodes`. The `syntax` target skips it for that reason.

## Architecture

Four pieces, deliberately decoupled:

1. **`sbin/pve-hpe-ilo-poller`** — systemd daemon. Polls iLO every 30s and
   writes `/run/pve-hpe-ilo/telemetry.json` atomically (temp file + rename).
2. **`perl/PVE/HPEiLO/API.pm`** — registers `GET /nodes/{node}/hpe-ilo` on
   `PVE::API2::Nodes::Nodeinfo`. **Only reads the cache file.**
3. **`js/pve-hpe-ilo.js`** — the ExtJS panel, plus an override of
   `PVE.node.Config` that grafts the tab on.
4. **`scripts/pve-hpe-ilo-patch`** — applies, verifies and reverts the two
   one-line hooks into upstream Proxmox files.

The split between 1 and 2 is the load-bearing design decision: iLO 4 takes 1–3s
per Redfish call and tolerates few concurrent sessions, so the API handler must
never talk to the BMC. If you are tempted to make the endpoint fetch live data,
don't — it will block a `pvedaemon` worker on every GUI refresh.

### The two patched files

Proxmox VE has **no plugin API for the web UI**. `PVE::Storage::Plugin` is for
storage backends only and cannot add views or API routes; Proxmox staff have
confirmed no UI extension mechanism exists. Hence:

| File | What is added | Package that owns it |
| --- | --- | --- |
| `/usr/share/perl5/PVE/API2/Nodes.pm` | guarded `require` + `register()` before the trailing `1;` | `libpve-access-control` |
| `/usr/share/pve-manager/index.html.tpl` | `<script>` tag after the `pvemanagerlib.js` tag | `pve-manager` |

Rules that keep this survivable:

- **Never modify `pvemanagerlib.js`.** The tab is added via an `Ext.define`
  override in our own file. Editing the bundle is what makes other Proxmox
  mods break on every release.
- **Keep both hooks one line of intent each.** All logic lives in
  `PVE::HPEiLO::API`, so the patch itself never has to change.
- The API hook is wrapped in `eval` and the JS override in `try/catch`: a
  broken install must degrade to "tab missing", never to a dead `pvedaemon` or
  a blank GUI.
- An apt `DPkg::Post-Invoke` hook reapplies both after every apt run, because
  upgrading either package silently reverts them.

`scripts/pve-hpe-ilo-patch` honours `PVE_HPE_ILO_ROOT` as a path prefix, which
is how `t/patch.sh` tests it without a node. Keep that working when editing it.

### How the tab is grafted on, and why not the obvious way

The node view is a `Proxmox.panel.Config`. Its left-hand navigation looks like
a tab bar but is an **`Ext.list.Tree`**, and the toolkit builds that tree store
**once** inside `initComponent`, converting each entry of `me.items` into an
`Ext.data.TreeModel` node keyed by `itemId`.

The consequence, learned the hard way: overriding `PVE.node.Config` and calling
`me.add()` after `callParent()` **silently does nothing visible**. The card is
created, the navigation entry is not, no exception is raised, and the
`try/catch` never fires. The symptom is a tab that does not exist and a console
with nothing in it.

The working seam is to override the **parent** class's `initComponent` and push
onto `me.items` *before* `callParent()`. `PVE.node.Config.initComponent` has
already filled the array by then (it does `me.items = []`, pushes, then calls
up), and `me` is still the node config instance, so `me.pveSelNode` is
available. A `me.$className === 'PVE.node.Config'` guard keeps the override out
of every other config panel in the GUI, which share that parent.

**Never hardcode the parent class name.** On PVE 9.2.18 it is
`PVE.panel.Config`, *not* `Proxmox.panel.Config`, and it has moved between
releases. Worse,
`Ext.define({override: 'Some.Missing.Class'})` queues the override until that
class appears and reports *nothing* if it never does — no tab, no exception, an
empty console. `installOverride()` therefore reads
`Ext.ClassManager.get('PVE.node.Config').superclass.$className` at load time.
The immediate superclass is correct by construction: it is where
`PVE.node.Config.initComponent`'s own `callParent()` lands.

Two console-readable flags exist for diagnosis, and they separate the three
failure modes cleanly:

| | Meaning |
| --- | --- |
| `PVE.hpe` undefined | the file never loaded |
| `PVE.hpe.overrideInstalled` false | the parent class could not be resolved |
| `PVE.hpe.injected` false | override installed but the push did not happen |

Anything that adds a second panel must go through `me.items`, never `add()`.

### iLO 4 vs iLO 5 normalization

`perl/PVE/HPEiLO/Redfish.pm` hides the firmware differences; everything
downstream sees one shape. The differences that bite:

| | iLO 4 | iLO 5+ |
| --- | --- | --- |
| Fan fields | `FanName` / `CurrentReading` / `Units` | `Name` / `Reading` / `ReadingUnits` |
| OEM block | `Oem.Hp` | `Oem.Hpe` |
| Base path | `/redfish/v1`, or `/rest/v1` below firmware 2.00 | `/redfish/v1` |

Entries with `Status.State` of `Absent`/`Disabled` are dropped — iLO lists empty
fan bays and unwired sensors with a reading of 0. A non-intake sensor reading
exactly 0 is also dropped, for the same reason.

**iLO sends `0`, not `null`, for values it does not have.** This is the trap
that survives every offline test and only shows up on real hardware:

- Thresholds that do not exist come back as `0`, so a `//` fallback chain picks
  the zero and reports that a CPU is critical at 0 °C. Use `_threshold()`,
  which skips anything not `> 0`.
- A P440ar often passes no drive temperature or power-on hours out of band and
  sends `0` for both. Use `_nonzero()` so the panel shows `-` instead of
  claiming a disk sits at freezing point.

Apply the same suspicion to any new field: on this firmware, zero usually means
absent.

Two more real-hardware details worth keeping:

- Every PSU reports the same generic `Name` (`HpServerPowerSupply`), so supplies
  are labelled from `Oem.Hp.BayNumber`, falling back to array position.
- `BackupPowerSourceStatus` has four values — `Present`, `PresentAndCharged`,
  `PresentAndCharging`, `NotPresent`. Only the last is a fault. Treating
  anything but `PresentAndCharged` as a warning produces a permanent false
  alarm on a P440ar, which reports plain `Present`.

These mappings are pinned by `t/normalize.t` against recorded payloads in
`t/fixtures/`. **Add a fixture when adding firmware support**; there is no way
to test against real hardware from the dev machine.

`collect(%opt)` lets each section (`ilo`, `thermal`, `power`, `system`,
`storage`) fail independently into `errors.<section>`, so one unsupported
endpoint on old firmware does not blank the whole panel.

### Smart Array: why it is on a separate schedule

`read_storage()` walks the OEM `SmartStorage` tree, which means **one HTTP
request per physical drive** — on iLO 4, one to three seconds each. A full walk
on a populated DL380 can take the best part of a minute.

So it is opt-in per call (`collect(storage => 1)`) and the poller runs it on
`storage_interval` (300s) rather than `interval` (30s), carrying the last good
result forward and reporting `storage_age` alongside it. The poller tracks two
separate timestamps and they must not be merged: `$last_storage_ts` is the age
of the *data*, `$next_storage_try` is the *schedule*, so that a failed walk
backs off instead of retrying on the fast cycle.

Gen9 reports SmartStorage out-of-band, but some fields do not populate at all:
on a P440ar, drive temperatures and power-on hours come back as `0`. Treat
missing fields as normal and render them as `-`.

**AMS is not the fix for those gaps on this hardware.** Checked against the HPE
repo, not forum folklore: `amsd` is the iLO 5 package (HPE's own description
says so), and `hp-ams`, the iLO 4 one, is built only for `jessie` — every suite
from `stretch` onward carries `amsd` alone. So there is no AMS for a Gen9 on a
current Debian.

`ssacli` is not the fix either: on third-party disks in HP carriers it omits
the temperature and run-time lines entirely, exactly as iLO does. Both read the
same backplane channel, which only carries that data for drives with HPE
firmware.

`PVE::HPEiLO::Smart` is the answer. `smartctl -d cciss,N /dev/sgX` reaches each
drive through the controller's passthrough and bypasses the backplane, so it
works with any disk. smartmontools ships with Proxmox, so this keeps the
no-extra-packages promise; `available()` degrades to a no-op if it is absent.

Two things about it are not negotiable:

- **Join by serial number, never by index.** The `cciss,N` order does not follow
  bay order — on the reference machine index 0 is the disk in bay `1I:3:4`.
  A positional join silently attributes readings to the wrong disk.
- **Never overwrite a value Redfish supplied.** `enrich()` fills only fields
  that are still undefined, so a firmware that does report temperatures stays
  authoritative.

With the `hpsa` driver the device node is `/dev/sg*`, not `/dev/sda`. Any
scsi-generic node on the controller addresses the same drives, so the first one
that answers is cached for the life of the poller.

Old iLO 4 firmware also predates parts of the schema: a system resource typed
`#ComputerSystem.1.0.1.ComputerSystem` has no `Oem.Hp.AggregateHealthStatus`,
so the per-subsystem health badges are simply unavailable there. Missing is
missing — do not synthesize a rollup to fill the space.

## Constraints

- **Core Perl only.** `HTTP::Tiny`, `MIME::Base64`, `POSIX` plus `JSON`, all
  present on a stock Proxmox node. Do not add CPAN or apt dependencies — the
  point is that installing this does not drag packages onto a hypervisor.
- **Essentially read-only.** The locate LED (`PVE::HPEiLO::Ssacli`) is the one
  exception and must stay the only one. Fan control is impossible (the BMC owns
  the curve), and RAID configuration is out of scope: iLO 4's `SmartStorage` is
  read-only and writable `SmartStorageConfig` is Gen10+. Anything that could
  destroy an array does not belong in a status panel, whatever the API allows.
- **Every write path validates its own arguments.** `Ssacli::valid_slot` and
  `valid_location` exist because those strings become `ssacli` arguments. The
  list form of `exec()` keeps a shell out of it, but ssacli would still read a
  crafted value as one of its own keywords. The API schema constrains them too;
  the module checks again because it is reachable from the command line.
  `t/ssacli.t` pins the rejections.
- **Version lives in `PVE::HPEiLO::Version` only.** The CLI, the poller's
  startup log, the API response and the panel header all read it from there.
- Credentials live in `/etc/pve-hpe-ilo/config.json`, mode 0600, deliberately
  **not** under `/etc/pve` — that path is group-readable by `www-data`
  (pveproxy).
- Error strings from `Redfish.pm` reach the browser. Never interpolate the
  password or the `Authorization` header into one.
