# Installing pve-hpe-ilo

Written for a DL380 Gen9 (iLO 4) running Proxmox VE 8 or 9. Every command runs
as root on the Proxmox node unless it says otherwise.

Work through part 1 before copying anything: if Redfish does not answer, the
rest is wasted effort, and the fix is in iLO rather than here.

---

## 1. Pre-flight

### 1.1 Check the iLO firmware

In the iLO web interface: **Information → Overview**, look at *iLO Firmware
Version*.

| Version | What you get |
| --- | --- |
| 2.30 or newer | Redfish at `/redfish/v1`. This is what you want. |
| 2.00 – 2.29 | Redfish present but incomplete; most readings work. |
| below 2.00 | No Redfish. Falls back to the legacy HP REST API at `/rest/v1`, which this package handles, but upgrading iLO is the better move. |

iLO 4 firmware is a free download from HPE and updating it does not reboot the
server — only the management processor.

### 1.2 Create a read-only iLO account

Do not reuse the administrator account. In iLO: **Administration → User
Administration → New**.

- Login name and password: your choice, e.g. `pve-monitor`
- **Leave every privilege checkbox unticked.**

An account with no privileges can still log in and read Redfish, which is
exactly the access this needs. If a credential leak ever happens, it cannot
power-cycle the host or mount virtual media.

### 1.3 Confirm the node can reach iLO

From the Proxmox node:

```sh
ILO=192.168.1.50      # your iLO address
curl -sk -o /dev/null -w '%{http_code}\n' "https://$ILO/redfish/v1/"
```

`200` is the answer you want. Anything else — no route, connection refused, a
timeout — is a network or firewall problem to solve first.

### 1.4 Confirm the credentials and the data

```sh
curl -sk -u 'pve-monitor:YOURPASSWORD' \
    "https://$ILO/redfish/v1/Chassis/1/Thermal/" | head -c 400; echo
```

You should see JSON containing `Temperatures` and `Fans`. Then the two that
matter for the rest of the panel:

```sh
curl -sk -u 'pve-monitor:YOURPASSWORD' \
    "https://$ILO/redfish/v1/Chassis/1/Power/" | head -c 200; echo

curl -sk -u 'pve-monitor:YOURPASSWORD' \
    "https://$ILO/redfish/v1/Systems/1/SmartStorage/" | head -c 200; echo
```

| Response | Meaning |
| --- | --- |
| JSON | Good. |
| `401` / `Unauthorized` | Wrong username or password. |
| `404` on `SmartStorage` only | Firmware too old, or no Smart Array controller. Set `"storage": false` later; everything else still works. |

`-k` skips certificate verification, which is necessary because iLO ships a
self-signed certificate. That is also the package's default (`insecure: true`).

### 1.5 Check the Perl modules

```sh
perl -MHTTP::Tiny -MJSON -MIO::Socket::SSL -e 'print "all present\n"'
```

All three are on a stock Proxmox node. If one is missing, the node is unusual —
`apt install libhttp-tiny-perl libjson-perl libio-socket-ssl-perl` fixes it.

---

## 2. Get the files onto the node

**Clone it on the node itself.** This is the only method that cannot leave you
with a half-updated install, which is the failure mode worth avoiding: copying
files by hand and missing one produces a node that runs new code against an old
module, and the symptoms make no sense.

```sh
apt install -y git
git clone https://github.com/Kamaar/pve-hpe-ilo.git /root/pve-hpe-ilo
```

Updating later is then one line, covered in section 10.

<details>
<summary>If the node has no internet access</summary>

Copy the working tree across with `scp`, `rsync`, WinSCP, or anything else that
transfers bytes verbatim:

```sh
cd /path/to/pve-hpe-ilo
scp -r . root@192.168.1.200:/root/pve-hpe-ilo
```

On Windows, `scp` ships with Git for Windows (available in Git Bash, not in
PowerShell unless you have installed the OpenSSH client feature). Run it from
inside the directory as shown — passing a path like `Z:\repo\proxmox` confuses
`scp`, which reads the drive letter's colon as a host separator.

Whatever you use, do **not** let it rewrite line endings: a shell script saved
with CRLF fails as `bad interpreter: /bin/bash^M`. In WinSCP this means setting
the transfer mode to **Binary** rather than Text, under Options → Preferences →
Transfer. Verify on the node:

```sh
head -c 20 /root/pve-hpe-ilo/install.sh | od -c | head -1   # expect \n, never \r \n
```

</details>

---

## 3. Install

```sh
cd /root/pve-hpe-ilo
./install.sh
```

It reports each step:

```
installing Perl modules to /usr/share/perl5/PVE/HPEiLO
installing executables to /usr/sbin
installing the panel to /usr/share/pve-manager/js
installing the systemd unit and apt hook
patching the Proxmox files
added API hook to /usr/share/perl5/PVE/API2/Nodes.pm
added GUI hook to /usr/share/pve-manager/index.html.tpl
restarting pvedaemon and pveproxy
```

The service is deliberately **not** started: the config file still holds the
example credentials.

Restarting `pvedaemon` and `pveproxy` does not touch running VMs or containers.
Open GUI sessions reconnect on their own.

---

## 4. Configure

```sh
nano /etc/pve-hpe-ilo/config.json
```

Set at least `host`, `username` and `password`:

```json
{
  "host": "192.168.1.50",
  "username": "pve-monitor",
  "password": "the-password-from-step-1.2",
  "insecure": true,
  "interval": 30,
  "storage": true,
  "storage_interval": 300
}
```

The `_comment*` keys in the example file are ignored; keep or delete them.

| Option | Default | Notes |
| --- | --- | --- |
| `interval` | 30 | Seconds between temperature/fan/power polls. Values below 10 are clamped. |
| `storage` | true | Set false if step 1.4 returned 404 on `SmartStorage`. |
| `storage_interval` | 300 | Smart Array costs one request per drive. Do not lower this to match `interval`. |
| `insecure` | true | Set false only after installing a trusted certificate in iLO. |
| `port` | 443 | |

Confirm the permissions — the file holds a password:

```sh
chmod 600 /etc/pve-hpe-ilo/config.json
ls -l /etc/pve-hpe-ilo/config.json      # expect -rw------- root root
```

It lives outside `/etc/pve` on purpose: that path is group-readable by
`www-data`, the user `pveproxy` runs as.

---

## 5. Test before starting the service

```sh
pve-hpe-ilo probe
```

Expect something like:

```
host:   192.168.1.50
status: ok
sample: 2026-09-14 22:41:03
server: ProLiant DL380 Gen9  bios P89 v2.76  sn CZJ...
ilo:    iLO 4 2.82 (redfish api)

health:
  system                 OK
  storage                OK

temperatures:
  01-Inlet Ambient          21C  warn -      crit 46C    OK
  02-CPU 1                  40C  warn -      crit 70C    OK
...
fans:
  Fan 1                     23 Percent
...
power:
  consumed                  212W
```

The first run takes a while — the Smart Array walk is one request per disk. Add
`--no-storage` to skip it.

Fields shown as `-` are normal. A Gen9 does not report everything: drive
temperatures and power-on hours usually come back empty through a P440ar, many
sensors have no critical threshold, and `DriveAccessName` is often absent. A
dash means iLO sent nothing, not that something is broken.

If this fails, the error names the cause. It is almost always credentials or
the address; go back to step 1.4.

Then start it:

```sh
systemctl enable --now pve-hpe-ilo
systemctl status pve-hpe-ilo
```

The first sample is not instant: the poller collects everything, Smart Array
included, before writing the cache. On a populated Gen9 that is a good half
minute. Wait for it, then:

```sh
pve-hpe-ilo show      # the cached sample the GUI reads
pve-hpe-ilo status    # one line; exit code 2 when something is unhealthy
```

---

## 6. Check the API before touching the browser

This separates a broken backend from a broken panel:

```sh
pvesh get /nodes/$(hostname)/hpe-ilo --output-format json | head -c 300; echo
```

JSON means the API hook is registered and the cache is readable. A *no such
resource* error means `pvedaemon` has not picked up the hook:

```sh
pve-hpe-ilo-patch --check
systemctl restart pvedaemon
```

---

## 7. Open the GUI

A **hard refresh is required** — the browser has `index.html` and the JS bundle
cached, and a normal reload will not fetch the new `<script>` tag.

- Windows/Linux: `Ctrl+Shift+R`
- macOS: `Cmd+Shift+R`

Then select any node in the left-hand tree. **Hardware (iLO)** appears in the
tab list, below the standard entries.

---

## 8. If the tab does not appear

Work down this list; each step rules out one layer.

**Is the script tag in the template?**

```sh
grep pve-hpe-ilo /usr/share/pve-manager/index.html.tpl
```

Nothing? Run `pve-hpe-ilo-patch`.

**Is the file being served?**

```sh
curl -sk -o /dev/null -w '%{http_code}\n' \
    "https://localhost:8006/pve2/js/pve-hpe-ilo.js"
```

`200` expected. `404` means the file is missing from
`/usr/share/pve-manager/js/`; re-run `./install.sh`.

**Is the browser loading it?** Open the developer tools (F12), reload, and look
in the Network tab for `pve-hpe-ilo.js`. If it is absent, the cache was not
cleared — try a private window.

**Did the JavaScript run, and did the graft take?** In the browser's developer
console (F12 → Console; in Chrome you must type `allow pasting` once before
pasting anything), enter:

```js
PVE.hpe.injected
```

| Result | Meaning |
| --- | --- |
| `true` | The tab was added to the node's navigation. If you still cannot see it, you are looking at a node you lack `Sys.Audit` on. |
| `false` | The file loaded but the entry was not added. Check `PVE.hpe.overrideInstalled`: `false` means the parent class of `PVE.node.Config` could not be resolved, any other value is the class name that was patched. Report whichever you get. |
| `Cannot read properties of undefined` | The file never ran. Go back to the two checks above. |

Note that the browser caches `pve-hpe-ilo.js` under the *pve-manager* version
string, which does not change when this package is updated. After updating,
a hard refresh is not optional — it is the only thing that fetches the new file.

**Does the tab appear but stay empty?** Check the message in the panel header —
it distinguishes *unconfigured*, *stale* and *error*. Then:

```sh
journalctl -u pve-hpe-ilo -n 50 --no-pager
```

---

## 9. After a Proxmox upgrade

Upgrading `pve-manager` or `libpve-access-control` replaces the two patched
files and silently removes the hooks. The apt hook at
`/etc/apt/apt.conf.d/99-pve-hpe-ilo` puts them back automatically after every
apt run.

To confirm by hand:

```sh
pve-hpe-ilo-patch --check
```

`both hooks are in place` is the answer you want. Otherwise run
`pve-hpe-ilo-patch`, then hard-refresh the browser.

A major upgrade (PVE 8 → 9) can change the GUI internals enough to break the
override. The failure mode is the tab disappearing, not the GUI breaking; the
console message from step 8 says so.

---

## 10. Updating this package

```sh
cd /root/pve-hpe-ilo && git pull && ./install.sh
```

That is the whole update. `install.sh` copies every module rather than a list
you have to keep current, keeps your existing `config.json`, reapplies the two
hooks, restarts the poller, and restarts `pvedaemon` and `pveproxy` — the last
one matters, because both cache what they have loaded and would otherwise keep
serving the previous version.

Then hard-refresh the browser (`Ctrl+Shift+R`). The panel JavaScript is cached
under the *pve-manager* version string, which does not change when this package
does, so a normal reload will not fetch it.

Check what a node is actually running:

```sh
pve-hpe-ilo version
```

---

## 11. Uninstalling

```sh
cd /root/pve-hpe-ilo
./install.sh --uninstall
```

This reverts both Proxmox files to their pristine backups, stops and removes
the service, the apt hook, the panel and the executables.

`/etc/pve-hpe-ilo/` is left behind so the credentials are not silently
destroyed. Remove it yourself:

```sh
rm -rf /etc/pve-hpe-ilo
```

---

## Reference: what gets installed where

| Path | Purpose |
| --- | --- |
| `/usr/share/perl5/PVE/HPEiLO/` | `Config.pm`, `Redfish.pm`, `API.pm` |
| `/usr/sbin/pve-hpe-ilo` | CLI |
| `/usr/sbin/pve-hpe-ilo-poller` | polling daemon |
| `/usr/sbin/pve-hpe-ilo-patch` | applies/verifies/reverts the hooks |
| `/usr/share/pve-manager/js/pve-hpe-ilo.js` | the panel |
| `/etc/pve-hpe-ilo/config.json` | credentials, mode 0600 |
| `/etc/systemd/system/pve-hpe-ilo.service` | unit |
| `/etc/apt/apt.conf.d/99-pve-hpe-ilo` | re-patch hook |
| `/var/lib/pve-hpe-ilo/backup/` | pristine copies of the two patched files |
| `/run/pve-hpe-ilo/telemetry.json` | cache, recreated at boot |

Modified, one line each: `/usr/share/perl5/PVE/API2/Nodes.pm` and
`/usr/share/pve-manager/index.html.tpl`.
