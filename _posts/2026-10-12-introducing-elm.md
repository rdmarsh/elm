---
layout: default
title: "Introducing elm: LogicMonitor data, one command away"
---

*12 October 2026*

If you run LogicMonitor, you have probably had a question like this land on
your desk:

- Which devices are in downtime right now, and who put them there?
- Which alerts have been open and unacknowledged for more than a week?
- Is our pre-production portal set up the same way as production?

The answer is in the portal somewhere. Getting it out usually means clicking
through screens, exporting what you can, and pasting it into a spreadsheet. Or
you write a script against the REST API and spend the first hour on HMAC
signing, paging and working out which filters really work.

I built [elm](https://github.com/rdmarsh/elm) so that the answer is one command.

```shell
# active critical alerts, newest first, as a table
elm -f pipe AlertList -s0 -S startEpoch -F cleared:false,severity:4 \
    -f monitorObjectName,dataPointName,alertValue

# the same query as CSV for a spreadsheet: change one flag
elm -f csv AlertList -s0 -S startEpoch -F cleared:false,severity:4 \
    -f monitorObjectName,dataPointName,alertValue
```

## What elm is

elm is a command-line tool for reading data out of LogicMonitor. It takes
care of authentication, paging and filtering, and it prints the result in the
format you need: CSV for a spreadsheet, JSON for a script, Markdown or HTML for
a report, Jira markup for a ticket. There are over 20 formats, and you switch
between them with `-f`.

It covers the whole API: more than 180 commands, one for each read endpoint,
from `DeviceList` and `AlertList` to `AuditLogList`, `SDTList`, collectors,
websites and LogicModules.

## Read-only, on purpose

elm only sends GET requests. It cannot create, change or delete anything in
your portal. The worst it can do is run a slow query.

That one decision shaped everything else. It makes elm safe to hand to a
colleague who is new to LogicMonitor, safe to put in a cron job, and safe to
give to an AI assistant.

## Built from the API's own description

elm's commands are not written by hand. The build reads LogicMonitor's
published API specification and generates a command for each endpoint, with its
parameters, help text and a list of every field it returns. When LogicMonitor
adds an endpoint, a rebuild picks it up.

Specifications are not always right, so elm also carries notes from testing
against real portals: filters the API quietly ignores, fields whose meaning is
not what the documentation says. `elm AlertList --info` shows them next to the
documented fields, without needing credentials.

## Comparing portals

If you look after more than one portal (production and pre-production, or one
per region), keeping them in step is a quiet, constant job. elm runs the same
query on several portals at once and can show only what differs:

```shell
elm -p prod,preprod -d -f csv DeviceGroupList -f name,appliesTo
```

The output lists only the groups that exist on one portal but not the other,
or whose rules differ. Like `diff`, it exits 0 when they match, so it fits into
a scheduled check.

## Plain-English questions

The newest piece is a prototype called
[elm-ask](https://github.com/rdmarsh/elm/tree/main/samara): a small web
page where someone who has never used a command line can type "which Windows
devices have alerts?" and get back an answer, a sortable table and the exact
elm queries used to produce it.

Because everything goes through elm, the assistant can only read. It also
uses its own credential profile, limited to an approved list of commands, and
secrets and contact details are removed before the model sees any data.

## Small tools, one job each

elm does one thing: get the data out. Everything else is built on top of it as
a separate script, the Unix way: backups of portal configuration, a collector
capacity report, a check for LogicModule updates, a PDF report comparing
portals. They live in
[`tools/`](https://github.com/rdmarsh/elm/tree/main/tools) alongside elm, and
each works by piping elm's output into the next step.

## How it was built

elm started in 2021 as a weekend script and has grown over almost 600 commits.
Much of the recent work was done alongside an AI coding assistant. The lesson
I would pass on is that it works best when the project's knowledge lives in
files rather than in chat: rules, decisions and test results written down where
both the people and the AI read them at the start of every session. I wrote
that approach up in
[ai.md](https://github.com/rdmarsh/elm/blob/main/ai.md).

## Try it

elm is free and open source under the GPL. It needs Python, `make` and a
LogicMonitor API token:

```shell
git clone https://github.com/rdmarsh/elm.git
cd elm
make && make install
```

The [README](https://github.com/rdmarsh/elm#readme) covers setup, and
[examples/](https://github.com/rdmarsh/elm/tree/main/examples) has recipes for
alerts, devices, collectors and more. Questions, ideas and bug reports are
welcome in the
[issue tracker](https://github.com/rdmarsh/elm/issues).

*LOGICMONITOR is a trademark of LogicMonitor, Inc. elm is an independent
project and is not affiliated with LogicMonitor.*
