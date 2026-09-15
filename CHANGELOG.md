# Changelog

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
