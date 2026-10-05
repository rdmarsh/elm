# Collector Readiness Check

Before adding a new collector to an auto-balance group, verify it can reach all
devices in that group. Once the collector joins, LM starts assigning devices to it
automatically — devices it can't reach will generate monitoring errors.

The standard workflow:

1. **Build** the new collector and leave it outside any group.
2. **Discover** devices and protocols using `tools/elm-collector-reach-paste.sh`.
3. **Generate** the test script (stdout redirect or clipboard).
4. **Test** reachability from the new collector in LM Collector Debug.
5. **Fix** any failures before moving the collector into the group.

**See also:**
- [collectors.md](collectors.md) for health checks and auto-balance group queries

<!--ts-->
   * [Step 1 — Find the auto-balance group](#step-1--find-the-auto-balance-group)
   * [Step 2 — Discover devices and generate the test script](#step-2--discover-devices-and-generate-the-test-script)
   * [Step 3 — Run the test from the new collector](#step-3--run-the-test-from-the-new-collector)
   * [Automated run across all collectors (PowerShell)](#automated-run-across-all-collectors-powershell)
      * [Vetting a new collector before adding it (-WithCollector)](#vetting-a-new-collector-before-adding-it--withcollector)
   * [Checking whether devices can move to a different group (-ToGroup)](#checking-whether-devices-can-move-to-a-different-group--togroup)
   * [Moving individual devices into a group (-WithDevice)](#moving-individual-devices-into-a-group--withdevice)
   * [Other ports (-Port), and results as objects (-PassThru)](#other-ports--port-and-results-as-objects--passthru)
   * [Interpreting results](#interpreting-results)
      * [SNMP TIMEOUT](#snmp-timeout)
      * [WMI (tcp-135)](#wmi-tcp-135)
   * [meta](#meta)
<!--te-->

## Step 1 — Find the auto-balance group

Run with no arguments to list auto-balance groups:

```shell
tools/elm-collector-reach-paste.sh
```

```
Auto-balance groups:

id    name                      collectors  threshold
----  ------------------------  ----------  ---------
42    My Region Collectors      3           500
87    APAC Collectors           2           500
```

Note the ID of the group you are adding the new collector to.

## Step 2 — Discover devices and generate the test script

The script always renders the Groovy test script to stdout. Redirect it to a file or
pipe to clipboard.

**By group ID — write to file:**

```shell
tools/elm-collector-reach-paste.sh --id 42 > /tmp/check.groovy
```

**By group name — write to file:**

```shell
tools/elm-collector-reach-paste.sh --name "My Region Collectors" > /tmp/check.groovy
```

**Copy directly to clipboard (macOS):**

```shell
tools/elm-collector-reach-paste.sh --id 42 | pbcopy
```

**With a non-default elm profile:**

```shell
tools/elm-collector-reach-paste.sh --id 42 --profile prod > /tmp/check.groovy
```

`--profile` defaults to `config` (the same default as elm — reads `config.ini`).

Status messages go to stderr so they don't pollute the redirected output:

```
Group:       My Region Collectors (id=42)
Collectors:  3
AutoBalance: true

Fetching devices in group 42...
Devices found: 47

Protocol legend: wmi=135, ssh=22, http=80, https=443 -- these are bare TCP
connect checks, NOT credential/protocol verification. A pass only means the
port accepted a connection, not that the named protocol/service works.

Device                           IP/Hostname             Protocols
-------------------------------- ----------------------  ---------
server01                         10.0.1.10               ping, snmp, ssh
windows-box                      10.0.1.20               ping, wmi
api-device                       10.0.1.30               ping, http, https
```

Protocol detection uses `autoProperties` set by LM Active Discovery on each device.
The IP/hostname used is the `name` field — the address LM uses to reach the device,
not `displayName`. **`wmi`/`ssh`/`http`/`https` are bare TCP connect checks** — no
protocol handshake, no credentials — named after the protocol that usually lives on
that port, but a pass only confirms the port is open, not that the protocol/service
actually works (the script prints a legend saying so, every run). `ping` and `snmp`
are real protocol tests (ICMP, and an actual SNMP `GetRequest`).

| autoProperty | Value | Test added | Port |
|---|---|---|---|
| `auto.snmp.operational` | `true` | SNMP probe (UDP 161) | 161 |
| `auto.network.listening_tcp_ports` | contains `22` | `ssh` (TCP connect only) | 22 |
| `auto.network.listening_tcp_ports` | contains `80` | `http` (TCP connect only) | 80 |
| `auto.network.listening_tcp_ports` contains `135`, or `auto.wmi.operational` | `135`, or `true` | `wmi` (TCP connect only — RPC endpoint mapper, necessary for WMI, not sufficient) | 135 |
| `auto.network.listening_tcp_ports` | contains `443` | `https` (TCP connect only) | 443 |
| _(always)_ | — | Ping (ICMP) | — |

If a device has no Active Discovery data yet (no `auto.network.listening_tcp_ports`),
only ping is tested. Run Active Discovery on the group in LM before using this tool
for best results.

## Step 3 — Run the test from the new collector

1. Open the LM portal and navigate to the new collector's device.
2. Go to **Collector Debug → Script** tab.
3. Paste the rendered Groovy (from file or clipboard) and run it.

Example output:

```
47 devices (pre-filled by elm)
Protocol legend: wmi=135, ssh=22, http=80, https=443 -- these are bare TCP connect
checks, NOT credential/protocol verification. A pass only means the port accepted
a connection, not that the named protocol/service works.

Device                           IP/Hostname          ping      snmp      ssh       wmi
-------------------------------- -------------------- --------- --------- --------- ---------
server01                         10.0.1.10            PASS      PASS      PASS      -
windows-box                      10.0.1.20            PASS      -         -         PASS
api-device                       10.0.1.30            PASS      -         -         -
unreachable-host                 10.0.2.99            FAIL      -         FAIL      -

FAILURES — investigate before adding this collector to the group:
  - unreachable-host  ping
  - unreachable-host  ssh
```

## Automated run across all collectors (PowerShell)

`tools/lm-collector-reach.ps1` does Steps 2-4 in a single pass for
**every active collector in the group at once**, then saves each collector's result as
`<hostname>.csv` so you can diff them to find reachability gaps between collectors.

It is self-contained PowerShell — it uses only the `Logic.Monitor` module (no elm,
bash, jq, or jinja2). It needs a Manage-level API token, because it runs Collector
Debug through the API; Steps 1–3 above need only elm's read-only token and your own
portal login, so use them where you cannot get a Manage token. Establish a session
first (`Connect-LMAccount`, or your own connection wrapper), then:

```powershell
# List collector groups
./tools/lm-collector-reach.ps1

# Run against a group by id or name
./tools/lm-collector-reach.ps1 -Group 42
./tools/lm-collector-reach.ps1 -Group "My Region Collectors" -OutputDir ./results
```

It discovers group members via `preferredCollectorGroupId`, builds the same protocol
matrix from `autoProperties`, generates the Groovy inline, submits it to each active
collector via Collector Debug, waits, and writes one CSV per collector.

When two or more collectors return, the script then prints a **built-in cross-collector
comparison** — for every device and protocol it gathers each collector's result and
lists only the rows where collectors disagree (e.g. one `pass`, another `FAIL`):

```text
-- Comparison: reachability gaps between collectors --

  api-device  [id=10293]
      http       collectorA=pass  collectorB=FAIL

3 device(s) differ between collectors; 26 agree.
```

This scales to any collector count — the odd collector out of eight is visible on the
per-protocol line, not just an A-vs-B comparison. The raw per-collector CSVs are still
written to the output directory if you want to eyeball them. For a full textual diff of
the two-collector case the script also prints a ready-to-run `difft` command (`difft` is
pairwise only, so it is suggested only when exactly two collectors returned):

```shell
difft results/collectorA.csv results/collectorB.csv
```

Devices that are themselves collector hosts (identified by a collector's
`collectorDeviceId`) are skipped — a collector is monitored from itself, so
cross-testing it from another collector is meaningless. If such hosts are found in an
auto-balance group the script warns: collector hosts should be pinned to their own
collector, not auto-balanced.

### Vetting a new collector before adding it (`-WithCollector`)

This is the pre-add check the whole workflow exists for: you built a new collector and
want to know whether it will reach everything a group monitors *before* you move it in.
Pass it with `-WithCollector` (collector id or hostname). The group still defines the
device list; the new collector — which is **not** in the group — gets that same list
submitted to it alongside the group's own collectors:

```powershell
# Will newedge02 reach everything group 191 monitors?
./tools/lm-collector-reach.ps1 -Group 191 -WithCollector newedge02
```

After the comparison, the script prints a **verdict** per new collector that lists
only the device+check combinations it fails to reach **but a current collector
does** — the real gaps it would introduce. Devices the current collectors already
can't reach are not counted against it.

```text
== Joining collector verdict: newedge02 ==
  2 gap(s) - it would NOT reach these, but a current collector does:
    https      windows-box  [id=10220]  joining=FAIL, current collector reaches it
    wmi        api-device   [id=10293]  joining=FAIL, current collector reaches it
  Fix routing/firewall for these before adding it.
```

If there are no gaps it prints "Reaches everything the current collectors reach. Ready
to add." Pass several comma-separated to vet them in one run.

## Checking whether devices can move to a different group (`-ToGroup`)

`-WithCollector` above vets one new collector against a group's devices. `-ToGroup`
vets a whole other group's collectors against them: "if I move this group's devices to
that group, will its collectors reach them?" Use it when moving devices between groups
or sites, and you want to know before the move whether every device would still be
reachable.

`-Group` still says which devices are tested, and its own collectors still run the test
as the baseline. To test the devices on particular collectors instead — for example one
being retired, which need not be in a group and may already be down — use `-Collector`
in place of (or as well as) `-Group`.

```powershell
# Would every device assigned to "Old Site" be reachable from "Consolidated Collectors"?
./tools/lm-collector-reach.ps1 -Group "Old Site" -ToGroup "Consolidated Collectors"

# The devices currently on legacy01/legacy02
./tools/lm-collector-reach.ps1 -Collector legacy01,legacy02 -ToGroup "Consolidated Collectors"
```

With more than one source of devices, the device summary table gets an extra `Source`
column showing where each device comes from. Then a **move verdict** classifies every
device:

```text
== Move verdict: 47 device(s) from Old Site -> Consolidated Collectors (id=42) ==

READY:   44 device(s) - every collector that would monitor them reaches them; safe to move.

BLOCKED: 1 device(s) - NO collector that would monitor them reaches at least one expected check:
  - unreachable-host  [id=10299]  (from Old Site)
      ping  collectorA=FAIL      collectorB=FAIL      (not reached from its current collectors either)

PARTIAL: 2 device(s) - SOME collectors that would monitor them reach them, some don't.
         Risky under auto-balance: the device could land on a collector that fails it.
  - windows-box  [id=10220]  (from Old Site)
      wmi   collectorA=pass      collectorB=FAIL
```

`BLOCKED` means no collector in the destination group can reach the device on an
expected check — fix routing/firewall before moving it, unless the line says it is
**not reached from its current collectors either**: then the device is already
unreachable, and the move is not what breaks it. `PARTIAL` only matters if the
destination group is auto-balance: LM could place the device on any of its collectors,
so a check that only some of them reach is a real risk even though *a* path exists.
`READY` devices are safe to move as-is.

## Moving individual devices into a group (`-WithDevice`)

To move one device, or a few, rather than a group's worth: name them with `-WithDevice`
(id or name, comma-separated). They are tested from the group's collectors, with each
device's current collector as its baseline, and get the same READY / PARTIAL / BLOCKED
verdict:

```powershell
./tools/lm-collector-reach.ps1 -Group "Site A" -WithDevice server01,server02

# or onto one collector rather than a group
./tools/lm-collector-reach.ps1 -Collector collector01 -WithDevice server01
```

## Other ports (`-Port`), and results as objects (`-PassThru`)

`-Port` replaces the built-in checks with the TCP ports you name, tested on every
device — for example WinRM, which the built-in checks do not cover:

```powershell
./tools/lm-collector-reach.ps1 -Group "Site A" -Port 5985,5986
```

`-PassThru` also sends one object per device, check and collector down the pipeline
(`Device`, `DeviceId`, `Address`, `Source`, `Check`, `Collector`, `Role`, `Result`,
`Verdict`), while the report still goes to the screen. `Role` is `current` (monitors
the device today), `joining` (a `-WithCollector`) or `destination` (where the device
would go, with `-ToGroup` or `-WithDevice`); `Verdict` is set for moves only:

```powershell
./tools/lm-collector-reach.ps1 -Group "Old Site" -ToGroup "New Site" -PassThru |
    Where-Object Verdict -eq BLOCKED | Export-Csv blocked.csv
```

## Interpreting results

| Result | Meaning |
|--------|---------|
| `PASS` | Connection succeeded |
| `FAIL` | Connection refused or timed out — routing or firewall issue |
| `TIMEOUT` | SNMP only: no UDP response within timeout |
| `-` | Protocol not expected for this device; skipped |

### SNMP TIMEOUT

`TIMEOUT` on SNMP does **not** necessarily mean the device is unreachable. The probe
is a hardcoded **SNMPv2c** `GetRequest` with community `public` — it cannot succeed
against anything that isn't SNMPv2c with that exact community, for two distinct
reasons that both present as the identical `TIMEOUT`:

- **Wrong community.** SNMP agents that enforce community strings silently drop
  probes with unknown communities instead of sending an error response. If the
  device uses a different community, you get `TIMEOUT` even though the agent is
  running and the port is open.
- **SNMPv3-only device.** This is the bigger one in practice, and easy to miss: if
  the device (or the whole portal) has moved to SNMPv3 — common for security/
  compliance reasons — a v2c-formatted probe gets no response at all, same as the
  above. If SNMPv3 is used anywhere in this portal, it is likely the **dominant**
  source of `TIMEOUT` results here, not a real reachability problem. There is
  currently no way for this probe to detect or test v3.

If `ping` passes but `snmp` shows `TIMEOUT`, check the device's `snmp.community`
property in LM (v2c) or whether it's configured for SNMPv3 at all, and verify the
collector can reach UDP 161 from the network level. To check a specific device
properly, use the collector debug console's `!snmpdiagnose` command — it runs a
real SNMP get/walk with the actual configured version/community/v3 credentials and
gives a specific diagnosis (e.g. "Unknown security name — check `snmp.security`
host property") instead of a blind `TIMEOUT`. See `collector-debug-notes.md`.

### WMI (tcp-135)

TCP 135 is the WMI/DCOM endpoint mapper. A passing `wmi` check means the
Windows RPC endpoint is reachable from the new collector, which is the necessary
precondition for WMI collection. It is a bare TCP connect test, **not** a WMI
credential check — despite the name, a pass does not mean WMI itself would
actually work (see `collector-debug-notes.md` for `!wmi`, a real credentialed
WMI test — with caveats about when it can and can't be used for this kind of
pre-move check).

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --hide-footer --skip-header examples/collector-readiness.md
```
