---
layout: default
title: elm
description: LogicMonitor tools that look but don't touch
---

Two tools for getting answers out of LogicMonitor, the monitoring platform:
elm on the command line, and Samara in plain English. Both only read, so
nobody using them, person or AI assistant, can change the data or settings
in your portal.

## elm

A command-line tool for the LogicMonitor API. Every list in the portal is a
command, and the answer comes back in whatever you need next: a table, CSV
for a spreadsheet, JSON for a script, Markdown or HTML for a report.

Open alerts from the last day, oldest first, in local time:

```shell
$ elm --localtime --format txt \
    AlertList \
      --filter 'cleared:false,startEpoch>:now-1d' \
      --fields severity,monitorObjectName,dataPointName,startEpoch \
      --sort startEpoch
  severity  monitorObjectName  dataPointName         startEpoch
         4  ap01               isOnline              2026-10-30 23:17:13 AEDT
         2  dc01               Offset                2026-10-31 15:09:52 AEDT
         2  ts01               Offset                2026-10-31 15:12:15 AEDT
         2  web01              hrStorageUsedPercent  2026-10-31 15:44:14 AEDT
         2  vm01               status                2026-10-31 17:23:53 AEDT
```

Options before the command name are elm's own (how to show the results);
after it, they belong to the command (what to fetch). No epochs to work
out either: `now-1d`, `now-1h` and dates like `2026-07` all work.

Use it when clicking through the portal is too slow, or the answer needs to
go somewhere else.

### try it

You need `make`, `jq` and Python 3.

```shell
git clone https://github.com/rdmarsh/elm.git
cd elm
make && make install
```

Then put your API credentials in `~/.config/logicmonitor/credentials/config.ini`
(`make` puts an example next to it) and run `elm DeviceList -c` to count your
devices. [The manual](https://github.com/rdmarsh/elm#readme) has the rest.

## Samara

A web page where you ask about your portal in plain English: "what devices
have alerting disabled?", "is anything in maintenance this weekend?". It runs
elm underneath, answers with the tables it found, and shows the queries so
you can run them again without any AI.

It runs on your own machine, with Claude or with a local model. With a local
model, your portal data isn't sent to an AI company. Getting local models to
answer as well is what I'm working on now. [Set it up]({{ "/samara/" | relative_url }}).

![Samara answering "is web01 okay?": up, with four open alerts in a table, one acknowledged with a note]({{ "/samara/samara.png" | relative_url }})

## posts

{% for post in site.posts limit:5 %}* [{{ post.title }}]({{ post.url | relative_url }}) ({{ post.date | date: "%Y-%m-%d" }})
{% endfor %}
[RSS]({{ "/feed.xml" | relative_url }})

## also here

* [examples](examples/README.md): recipes for alerts, collectors, health
  checks, comparing portals and more
* [tools](tools/README.md): scripts built on elm
* [working with an AI assistant](ai.md): how elm is built with Claude Code
* [changelog](CHANGELOG.md)

I'm David Marsh. I look after LogicMonitor at work and built these for that.
Both are open source (GPL-3.0):
[github.com/rdmarsh/elm](https://github.com/rdmarsh/elm).

*LOGICMONITOR is a trademark of LogicMonitor, Inc. elm is an independent
project and is not affiliated with LogicMonitor.*
