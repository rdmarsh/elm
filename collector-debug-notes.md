# Collector Debug Facility Notes

A living document for LogicMonitor's **Collector Debug Facility** — the
`!`-prefixed commands run against a specific collector (via the LM portal's
Debug Command dialog, or the `Logic.Monitor` PowerShell module's
`Invoke-LMCollectorDebugCommand`/`Get-LMCollectorDebugResult`).

**Scope note:** this is a different subsystem from what `elm-notes.yaml` and
`elm-knowledge.md` cover. Those two are about the LM **REST API** (the surface
`elm` wraps — `DeviceList`, `CollectorGroupList`, etc.). This file is about
commands that run **on a collector itself** and talk to monitored devices
directly (WMI, SNMP, WinRM, raw sockets, ...). There is no overlap; if a note
is about a REST API endpoint/field, it belongs in the other two files instead.

Requires a Manage-level API token / role for Collector Debug (a read-only
token gets "Access denied" — same requirement noted in
`tools/lm-collector-run-groovy.ps1`). Get command usage from the console
itself with `help !<commandname>`.

## Full command list (from `help`, verbatim)

Captured live 2026-08. One-line descriptions are the collector's own; not
independently verified beyond what's explored in detail below.

| Command | Description |
|---|---|
| `!account` | display account information used by sbwinproxy |
| `!adetail` | show detail info of an AutoDiscovery task |
| `!adlist` | list AutoDiscovery tasks |
| `!apdetail` | show detail info of an AutoProps task |
| `!aplist` | list AutoProps tasks |
| `!avslist` | list all installed anti-virus software in system |
| `!checkcredential` | check the credential usages |
| `!checkserverconnectivity` | check the santaba server connectivity |
| `!cim` | execute a cim query against the given host and print the result |
| `!cp` | copy file in `<agentRoot>` directory |
| `!debugdetail` | get the output of a debug command |
| `!debughistory` | get the history of debug command executed |
| `!DecryptFileSHA` | get the decrypted SHA of a specific file (or all files in JSON if no filename given) |
| `!digest` | calculate file checksum MD5/SHA1/SHA-256, default MD5 |
| `!dir` | list files under folder |
| `!dumpheap` | dump collector JVM heap info |
| `!esx` | execute ESX query for the given host |
| `!etw` | execute a command to catch ETW information |
| `!firewallstatus` | show firewall settings |
| `!getconfig` | get collector configuration item value |
| `!groovy` | execute a groovy script (absolute path or relative to `<agentRoot>/bin`) |
| `!healthCheckV2` | execute healthCheck groovy script — internal use only |
| `!hostproperty` | add, update or delete a system property for the given host |
| `!http` | send an HTTP request and return the response |
| `!ipaddress` | show the agent's IP config |
| `!java` | execute a java command on the agent's host machine |
| `!jcmd` | execute jcmd command on the collector |
| `!jdbc` | execute a SQL query for the given host |
| `!jmx` | query a JMX path for the given host or URL |
| `!jssl` | get SSL info for the given host |
| `!keepagentalive` | keep agent alive for a given period |
| `!log4jloglevel` | change the log level of a log4j component |
| `!logfile` | diagnose logfile event source |
| `!logingestion` | show Queue/Filter/Syslog API/Ingest API communication status |
| `!loglevel` | change the log level of an agent component |
| `!logman` | execute logman.exe on the agent's host machine |
| `!logsearch` | search log based on rules |
| `!logsurf` | surf the log file |
| `!macaddress` | get the MAC address for the given host |
| `!mongo` | execute a mongo query |
| `!netapp` | call the NetApp API for the given host |
| `!netflow` | get netflow information |
| `!nslookup` | resolve IP of the given host |
| `!nspdetail` | show detail info of a net scanning task |
| `!nsplist` | show all net scanning tasks |
| `!opssl` | execute openssl command for the given host |
| `!packetcapture` | packet capture via tcpdump (Linux) or netsh (Windows) |
| `!packetcapture2` | packet capture via pcap |
| `!perf` | get collector performance analysis |
| `!perfinfo` | query a list of performance counters info against the given host |
| `!perfmon` | query a list of performance monitor counters against the given host |
| `!ping` | ping a given host |
| `!posh` | execute a PowerShell script (absolute path or relative to `<agentRoot>/bin`) |
| `!put` | copy a file under server `$company/scripts` to `<agentRoot>/tmp` |
| `!reducelog` | enable or disable the reduce logger |
| `!register` | update collector description |
| `!reload` | force reload of agent configuration from server |
| `!replace` | copy `<agentRoot>/tmp/<source>` to `<agentRoot>/<dest>` |
| `!reportercache` | show status of BufferDataReporter |
| `!restart` | restart collector or watchdog |
| `!sbshutdown` | execute sbshutdown.exe in `<agentroot>\bin` on the agent's host machine |
| `!sconfig` | set or get internal website configs |
| `!sdetail` | list the execution of internal website execution |
| `!slist` | list detail of a task (taskid from `!tlist`) |
| `!snmpdiagnose` | diagnose SNMP OID for the given host — see below |
| `!snmpget` | get the values of a list of OIDs from the given host |
| `!snmptrap` | diagnose snmptrap event source |
| `!snmpwalk` | walk the OID from the given host |
| `!spdetail` | show detailed info for a specified script task |
| `!splist` | list latest script property tasks in collector |
| `!sslcerts` | print SSL certificate info for the given host |
| `!ssltest` | test SSL connection status |
| `!svc` | execute a service management command on the agent's host machine |
| `!syslog` | diagnose syslog event source |
| `!syslogsender` | send a syslog message to the given host |
| `!syswmic` | execute wmic.exe command on the agent's host machine |
| `!tail` | tail the given file with regex |
| `!taskkill` | kill a specified process on the agent's host machine |
| `!tasklist` | list processes on the agent's host machine |
| `!tcancel` | disable a collecting task |
| `!tdetail` | list detail of a task (taskid from `!tlist`) |
| `!tlist` | list collecting tasks (datasource, configsource, eventsource) |
| `!tpdetail` | show detailed info of topology tasks |
| `!tplist` | list topology tasks |
| `!tremove` | disable a collecting task |
| `!typeperf` | execute typeperf.exe on the agent's host machine |
| `!unzip` | unzip the given zipped file |
| `!upgradeproxy` | upgrade sbwinproxy or sblinuxproxy from `<agentroot>/tmp` |
| `!uploadlog` | upload specified log files |
| `!uptime` | show agent uptime |
| `!webperf` | send an HTTP request and print metrics |
| `!winevent` | collect Windows event log |
| `!winrm` | test if WinRM config is correct — see below (collector v36.000+) |
| `!wmi` | execute a WMI query — see below |
| `!wmimethod` | call a WMI method |
| `!xen` | query a Xen server counter against the given host |

No native `!tcp` (bare TCP port-open check) exists — this is presumably why
the reachability/move-readiness Groovy checks hand-roll their own
`Socket.connect()` for port checks instead of calling a native command; there
isn't one. `!http` and `!ssltest`/`!sslcerts` DO exist natively though, and
are real protocol tests unlike the current hand-rolled `tcpOk(ip, 80/443, ...)`
— worth investigating for a future upgrade (see RECOMMENDATIONS.md item 18).

## Commands explored in detail

### `!wmi` — real WMI query

```
usage: !wmi [username=foo password=bar] h=<host> <wmi query>
      If you don't give the username/password, the agent will use wmi.user/wmi.pass
      properties of the host.
example: !wmi h=paz02sql002 select * from win32_operatingsystem
```

### `!winrm` — real WinRM test

```
Usage : !winrm host=<Computer Name> [auth=<Auth Type>] [useSSL=true|false] [certCheck=true|false] [username=foo] [password=var] [query=winrmquery]
     host = (mandatory) Remote Domain Computer which we are monitoring
     auth = (optional) Authentication Type, default value is `Negotiate`
     useSSL = (optional) WinRM data collection over HTTPS, default value is `true`
     certCheck = (optional) Certificate Check, default value is `true`
     username, password = (optional) Domain User Credentials, Will use wmi.user / wmi.pass if not passed
     query = (optional) WQL Query, default value is `select * from Win32_Service`
     timeout = (optional) timeout value in secs for the above WQL Query, default value is 60 secs
example : !winrm host=EC2AMAZ-93376C4.logicmonitor.com auth=Kerberos username=LOGICMONITOR\user_name password=user_secret useSSL=false certCheck=false
```

Requires collector version 36.000+.

### `!snmpdiagnose` — real SNMP test (v1/v2c/v3)

```
Usage: !snmpDiagnose [OPTIONS] host [oid [oid] ...]
  version=v1|v2c|v3           specifies SNMP version to use, default is v2c
  community=public            set the community string, default is public
  auth=MD5|SHA|SHA224|SHA256|SHA384|SHA512  set the authentication protocol
  authToken=string            set the authentication protocol pass phrase
  contextName=context         set the context name
  security=string             set the security name
  priv=DES|AES|AES128|AES192|AES256|3DES|... set the privacy protocol
  snmpEngineId=ENGINE-ID / contextEngineId=ENGINE-ID / localEngineId=ENGINE-ID
  retries=int                 default 1
  timeout=int                 default 5 (seconds)
  maxSizeResponse=int         default 65535
  pduType=GET|WALK
  srcPort=int / port=int      default port 161
  reqId=int
  transport=udp|tcp           default udp
  taskTimeout=int             default 120 (seconds)
```

Runs a multi-step diagnosis (ping, then SNMP get/walk/bulkwalk), printing the
exact `snmpget.exe`/`snmpwalk.exe`/`snmpbulkwalk.exe` command line it ran and
a plain-English `Suggestion:` on failure (e.g. "Please check the security
option and `snmp.security` host property" for a bad v3 security name). Far
more diagnostic than the reachability tools' current hand-rolled UDP
`GetRequest` probe (hardcoded SNMPv2c, community `public`, pass/FAIL/TIMEOUT
only — see `tools/lm-collector-reachability-check.groovy.j2`).

### `!healthCheckV2` — signed script only, not usable from the console

```
Usage:
    !healthCheckV2 jsonObject
Arguments:
    jsonObject: Contains the script body for the healthcheck script and verification params
example:
   !healthCheckV2 {"signAlgorithm":"","region":"","signature":"","keyID":"","scriptBody":"","scriptName":""}
```

Captured live 2026-08 via `help !healthCheckV2`. The `jsonObject` argument
wants a **signed payload**: `scriptBody`/`scriptName` carry the Groovy
healthcheck script itself, while `signAlgorithm`/`signature`/`keyID` are a
signature over that script, presumably checked against a key LM's own backend
holds. That signature gate is almost certainly why the command is flagged
"internal use only" in the `help` list — there's no way to construct a
`scriptBody` that passes verification without LM's private signing key, so
this is LM's own mechanism for pushing signed healthcheck scripts to
collectors, not a customer-facing diagnostic. Not independently tried against
a live collector (no way to produce a valid `signature`/`keyID`), but the
help text alone is enough to explain the earlier `[object Object]` failures
seen when calling it bare or with `help` as a positional arg — those weren't
signature failures, just malformed-JSON-argument failures, and the console UI
renders the resulting exception as an unstringified object instead of text.

**If you actually want to run your own healthcheck-style script against a
collector, use `!groovy` instead** (path to a script, absolute or relative to
`<agentRoot>/bin`, no signature required) — or the existing
`tools/lm-collector-run-groovy.ps1` wrapper, which already does this for
`CollectorHealthCheck.groovy` (see `tools/README.md`).

### `!ping`

```
Usage: !ping [type=default|all|proxy|sys|java] [count=10] <host>
      count: the number of send package, optional
      host: the host was ping
      type: the ping implementation type, optional
              default - decided by conf pingpool.usejava. when pingpool.usejava=true, will use java ping, else use proxy ping.
              all     - run all types of ping to help to compare results
              proxy   - use sbproxy to do ping requests
              sys     - use system ping command
              java    - use java ping
example: !ping www.google.com
```

## Key finding: credential auto-resolution is scoped to the current collector

`!wmi`/`!winrm`/`!snmpdiagnose` all fall back to the target device's stored
credentials (`wmi.user`/`wmi.pass`, or the v3 `snmp.security`/auth/priv
properties) when no explicit credentials are passed — but **only when the
device is currently monitored by the collector you're running the command
from.** Confirmed live (2026-08): running the exact same
`!snmpdiagnose version=v3 <host>` against the same device from two different
collectors produced two different results — a generic
`securityName=logicmonitor`/`noAuthNoPriv` (which failed, "Unknown user
name") from a collector that does not monitor that device, and the device's
real, working v3 security name/auth/priv from the collector that does. Same
finding backs the `WMI.queryAll()` Groovy-API javadoc, which states outright
it only applies "to the host which is monitored by current collector."

**Why this matters:** the whole point of `tools/lm-collector-reachability-run-all.ps1`,
`tools/lm-collector-move-readiness-run-all.ps1`, and their `-Candidate`/
`-SourceCollector` modes is testing a collector that does **not** yet monitor
the device (a candidate being vetted, a target group before a move) — exactly
the case where this auto-resolution doesn't apply. Full detail and the
resulting scoping decision (record a separate future diagnostic tool instead
of rewriting the existing scripts) is in `RECOMMENDATIONS.md` items 17 and 18.

## Open questions / not yet verified

- Whether `Invoke-LMCollectorDebugCommand -GroovyCommand` (the `Logic.Monitor`
  PowerShell module cmdlet the existing tools use) can submit a raw
  `!`-prefixed command verbatim, or whether it only accepts actual Groovy
  code and `!`-commands need a different invocation path. Untested — needs a
  live check before any tool tries to use `!wmi`/`!winrm`/`!snmpdiagnose`
  programmatically.
- `!checkcredential` ("check the credential usages") is unexplored — name
  suggests it might answer "which credential would be used for this host"
  without actually running a query. Could be relevant to a future diagnostic
  tool; not yet tried.
- `!http`/`!ssltest`/`!sslcerts` are real protocol tests (unlike the current
  hand-rolled `tcpOk(ip, 80/443, ...)` bare socket checks) but haven't been
  tried against a real device yet.
