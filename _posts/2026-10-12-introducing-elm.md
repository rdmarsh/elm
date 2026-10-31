---
layout: default
title: "introducing elm (logicmonitor data without the clicking)"
---

*2026-10-12*

tldr; I built [elm](https://github.com/rdmarsh/elm), a command-line tool that
gets data out of LogicMonitor in one command, in whatever format you need
next. It only reads, so it can't change anything in your portal.

If you look after LogicMonitor, you've probably been asked something like
this:

* Which devices are in downtime right now, and who put them there?
* Which alerts have been open and unacknowledged for more than a week?
* Is our pre-production portal set up the same way as production?

The answer is in the portal somewhere. Getting it out usually means clicking
through screens, exporting what you can, and pasting it into a spreadsheet. Or
you write a script against the REST API and spend the first hour on HMAC
signing, paging and working out which filters actually work.

I built elm so the answer is one command.

```shell
# open critical alerts, newest first, as a table
elm -f pipe AlertList -s0 -S startEpoch -F cleared:false,severity:4 \
    -f monitorObjectName,dataPointName,alertValue

# the same query as CSV for a spreadsheet: change one flag
elm -f csv AlertList -s0 -S startEpoch -F cleared:false,severity:4 \
    -f monitorObjectName,dataPointName,alertValue
```

## what elm is

elm is a command-line tool for reading data out of LogicMonitor. It handles
the authentication, paging and filtering, and prints the result in the format
you need: CSV for a spreadsheet, JSON for a script, Markdown or HTML for a
report, Jira markup for a ticket. There are over 20 formats, and you switch
between them with `-f`.

It covers the whole API: more than 180 commands, one for each read endpoint,
from `DeviceList` and `AlertList` to `AuditLogList`, `SDTList`, collectors,
websites and LogicModules.

## read-only, on purpose

elm only sends GET requests. It can't create, change or delete anything in
your portal. The worst it can do is run a slow query.

Most of the other decisions follow from that one. It means elm is safe to hand
to someone new to LogicMonitor, safe to put in a cron job, and safe to give to
an AI assistant.

## built from the API's own description

I don't write elm's commands by hand. The build reads LogicMonitor's published
API spec and generates a command for each endpoint, with its parameters, help
text and every field it returns. When LogicMonitor adds an endpoint, a rebuild
picks it up.

The spec isn't always right, so elm also carries notes from testing against
real portals: filters the API quietly ignores, fields that don't mean what the
docs say. `elm AlertList --info` shows them next to the documented fields, and
doesn't need credentials.

## comparing portals

If you look after more than one portal (production and pre-production, or one
per region), keeping them in step is a job that never quite finishes. elm runs
the same query on several portals at once and can show only what differs:

```shell
elm -p prod,preprod -d -f csv DeviceGroupList -f name,appliesTo
```

The output lists only the groups that exist on one portal and not the other,
or whose rules differ. Like `diff`, it exits 0 when they match, so it works in
a scheduled check.

## plain-English questions

The newest piece is
[Samara](https://github.com/rdmarsh/elm/tree/main/samara) (it was called
elm-ask when this post went up): a small web page where someone who has never
used a command line can type "which Windows devices have alerts?" and get back
an answer, a sortable table and the elm queries that produced it.

Everything goes through elm, so it can only read. It also uses its own
credential profile, limited to a list of commands I've approved. Secrets and
contact details are removed before the model sees any data, and the model never
reads descriptions, notes or logins at all: you see them in the tables, it
doesn't.

## small tools, one job each

elm does one thing: get the data out. Everything else is a separate script on
top of it, the Unix way: backups of portal config, a collector capacity report,
a check for LogicModule updates, a PDF report comparing portals. They live in
[`tools/`](https://github.com/rdmarsh/elm/tree/main/tools) next to elm, and
each one pipes elm's output into the next step.

## how it was built

elm started in 2021 as a weekend script and has grown over almost 600 commits.
A lot of the recent work was done with an AI coding assistant. The main thing
I've learnt is that it works best when what the project knows lives in files,
not in chat: rules, decisions and test results, written down where both of us
read them at the start of every session. I wrote that up in
[ai.md](https://github.com/rdmarsh/elm/blob/main/ai.md).

## try it

elm is free and open source under the GPL. You need Python, `make` and a
LogicMonitor API token:

```shell
git clone https://github.com/rdmarsh/elm.git
cd elm
make && make install
```

The [README](https://github.com/rdmarsh/elm#readme) covers setup, and
[examples/](https://github.com/rdmarsh/elm/tree/main/examples) has recipes for
alerts, devices, collectors and more. Questions, ideas and bug reports are
welcome in the [issue tracker](https://github.com/rdmarsh/elm/issues).

*LOGICMONITOR is a trademark of LogicMonitor, Inc. elm is an independent
project and is not affiliated with LogicMonitor.*
