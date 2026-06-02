# Collector Readiness Check

Before adding a new collector to an auto-balance group, verify it can reach all
devices in that group. Once the collector joins, LM starts assigning devices to it
automatically — devices it can't reach will generate monitoring errors.

The standard workflow:

1. **Build** the new collector and leave it outside any group.
2. **Discover** devices and protocols using `tools/elm-collector-readiness.sh`.
3. **Generate** the test script (stdout redirect or clipboard).
4. **Test** reachability from the new collector in LM Collector Debug.
5. **Fix** any failures before moving the collector into the group.

**See also:**
- [collectors.md](collectors.md) for health checks and auto-balance group queries

<!--ts-->
   * [Step 1 — Find the auto-balance group](#step-1--find-the-auto-balance-group)
   * [Step 2 — Discover devices and generate the test script](#step-2--discover-devices-and-generate-the-test-script)
   * [Step 3 — Inject credentials (optional)](#step-3--inject-credentials-optional)
   * [Step 4 — Run the test from the new collector](#step-4--run-the-test-from-the-new-collector)
   * [Automated run across all collectors (PowerShell)](#automated-run-across-all-collectors-powershell)
      * [Vetting a new collector before adding it (-Candidate)](#vetting-a-new-collector-before-adding-it--candidate)
   * [Interpreting results](#interpreting-results)
      * [SNMP TIMEOUT](#snmp-timeout)
      * [WMI (tcp-135)](#wmi-tcp-135)
   * [Mode C — LM API directly, no elm](#mode-c--lm-api-directly-no-elm)
   * [meta](#meta)
<!--te-->

## Step 1 — Find the auto-balance group

Run with no arguments to list auto-balance groups:

```shell
tools/elm-collector-readiness.sh
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
tools/elm-collector-readiness.sh --id 42 > /tmp/check.groovy
```

**By group name — write to file:**

```shell
tools/elm-collector-readiness.sh --name "My Region Collectors" > /tmp/check.groovy
```

**Copy directly to clipboard (macOS):**

```shell
tools/elm-collector-readiness.sh --id 42 | pbcopy
```

**With a non-default elm profile:**

```shell
tools/elm-collector-readiness.sh --id 42 --profile prod > /tmp/check.groovy
```

`--profile` defaults to `config` (the same default as elm — reads `config.ini`).

Status messages go to stderr so they don't pollute the redirected output:

```
Group:       My Region Collectors (id=42)
Collectors:  3
AutoBalance: true

Fetching devices in group 42...
Devices found: 47

Device                           IP/Hostname             Protocols
-------------------------------- ----------------------  ---------
server01                         10.0.1.10               ping, snmp, tcp-22
windows-box                      10.0.1.20               ping, tcp-135
api-device                       10.0.1.30               ping, tcp-80, tcp-443
```

Protocol detection uses `autoProperties` set by LM Active Discovery on each device.
The IP/hostname used is the `name` field — the address LM uses to reach the device,
not `displayName`.

| autoProperty | Value | Test added |
|---|---|---|
| `auto.snmp.operational` | `true` | SNMP probe (UDP 161) |
| `auto.network.listening_tcp_ports` | contains `22` | TCP port 22 (SSH) |
| `auto.network.listening_tcp_ports` | contains `80` | TCP port 80 (HTTP) |
| `auto.network.listening_tcp_ports` | contains `135` | TCP port 135 (WMI/RPC) |
| `auto.network.listening_tcp_ports` | contains `443` | TCP port 443 (HTTPS) |
| _(always)_ | — | Ping (ICMP) |

If a device has no Active Discovery data yet (no `auto.network.listening_tcp_ports`),
only ping is tested. Run Active Discovery on the group in LM before using this tool
for best results.

## Step 3 — Inject credentials (optional)

By default the rendered script has blank credential fields; you fill them in manually
in the LM debug console before running. If you want credentials pre-filled from elm's
config, add `--creds`:

```shell
# Default elm profile (config.ini)
tools/elm-collector-readiness.sh --id 42 --creds | pbcopy

# Non-default profile
tools/elm-collector-readiness.sh --id 42 --creds --profile prod > /tmp/check.groovy
```

> **Note:** the rendered script from `--creds` contains your LM API credentials.
> Do not commit it to git or share it.

With credentials injected, the script can also call the LM API directly from the
collector to re-discover the device list — useful if you want to verify without
trusting the workstation-side output.

## Step 4 — Run the test from the new collector

1. Open the LM portal and navigate to the new collector's device.
2. Go to **Collector Debug → Script** tab.
3. Paste the rendered Groovy (from file or clipboard) and run it.

Example output:

```
47 devices (pre-filled by elm)

Device                           IP/Hostname          ping      snmp      tcp-22    tcp-135
-------------------------------- -------------------- --------- --------- --------- ---------
server01                         10.0.1.10            PASS      PASS      PASS      -
windows-box                      10.0.1.20            PASS      -         -         PASS
api-device                       10.0.1.30            PASS      -         -         -
unreachable-host                 10.0.2.99            FAIL      -         FAIL      -

FAILURES — investigate before adding this collector to the group:
  - unreachable-host  ping
  - unreachable-host  tcp-22
```

## Automated run across all collectors (PowerShell)

`tools/lm-collector-reachability-run-all.ps1` does Steps 2-4 in a single pass for
**every active collector in the group at once**, then saves each collector's result as
`<hostname>.csv` so you can diff them to find reachability gaps between collectors.

It is self-contained PowerShell — it uses only the `Logic.Monitor` module (no elm,
bash, jq, or jinja2). Establish a session first (`Connect-LMAccount`, or your own
connection wrapper), then:

```powershell
# List auto-balance groups
./tools/lm-collector-reachability-run-all.ps1

# Run against a group by id or name
./tools/lm-collector-reachability-run-all.ps1 -id 42
./tools/lm-collector-reachability-run-all.ps1 -group "My Region Collectors" -OutputDir ./results
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

### Vetting a new collector before adding it (`-Candidate`)

This is the pre-add check the whole workflow exists for: you built a new collector and
want to know whether it will reach everything a group monitors *before* you move it in.
Pass it with `-Candidate` (collector id or hostname). The group still defines the device
list; the candidate — which is **not** in the group — gets that same list submitted to
it alongside the group's own collectors:

```powershell
# Will newedge02 reach everything group 191 monitors?
./tools/lm-collector-reachability-run-all.ps1 -id 191 -Candidate newedge02
```

After the general comparison, the script prints a per-candidate **verdict** that lists
only the device+protocol combinations the candidate fails to reach **but an in-group
collector does** — the real gaps the candidate would introduce. Devices the whole group
already can't reach are not counted against the candidate.

```text
== Candidate verdict: newedge02 ==
  2 gap(s) - the candidate would NOT reach these, but a group collector does:
    https      windows-box  [id=10220]  candidate=FAIL, group reaches it
    wmi        api-device   [id=10293]  candidate=FAIL, group reaches it
  Fix routing/firewall for these before moving the candidate into the group.
```

If there are no gaps it prints "Reaches everything the group's collectors reach. Ready
to add to the group." You can pass `-Candidate` more than once (or a comma-separated
list) to vet several collectors in one run.

## Interpreting results

| Result | Meaning |
|--------|---------|
| `PASS` | Connection succeeded |
| `FAIL` | Connection refused or timed out — routing or firewall issue |
| `TIMEOUT` | SNMP only: no UDP response within timeout |
| `-` | Protocol not expected for this device; skipped |

### SNMP TIMEOUT

`TIMEOUT` on SNMP does **not** necessarily mean the device is unreachable. SNMP
agents that enforce community strings silently drop probes with unknown communities
instead of sending an error response. The probe uses community `public`; if the
device uses a different community, you will see `TIMEOUT` even though the agent is
running and the port is open.

If `ping` passes but `snmp` shows `TIMEOUT`, check the device's `snmp.community`
property in LM and verify the collector can reach UDP 161 from the network level.

### WMI (tcp-135)

TCP 135 is the WMI/DCOM endpoint mapper. A passing TCP-135 check means the
Windows RPC endpoint is reachable from the new collector, which is the necessary
precondition for WMI collection. It does not test WMI credentials.

## Mode C — LM API directly, no elm

If elm is not available, open `tools/lm-collector-reachability-check.groovy.j2` in an
editor, clear the `{{ devices_json | default('[]') }}` placeholder (leave `[]`), and
fill in the credentials block:

```groovy
def ACCESS_ID    = "your-access-id"   // remove after use
def ACCESS_KEY   = "your-access-key"  // remove after use
def ACCOUNT_NAME = "acme"
def GROUP_ID     = 42
// DEVICES_JSON stays as []
```

The script calls the LM API directly to discover devices. Remove the credentials from
the script after use — the LM debug console history may retain them.

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --hide-footer --skip-header examples/collector-readiness.md
```
