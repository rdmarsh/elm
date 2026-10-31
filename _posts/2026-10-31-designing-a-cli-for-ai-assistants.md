---
layout: default
title: "designing a cli for ai assistants"
description: "who never read the manual"
---

tldr; More and more commands in a terminal are typed by an AI assistant, not
a person. [elm](https://github.com/rdmarsh/elm), my command-line tool for
LogicMonitor, already suited that: it has been read-only from the start. So we
added what an assistant needs on top: short docs it can afford to read (`--ai`
and `--info`), errors that say how to fix the mistake, no silent failures, and
times written the way people say them, not as epochs. Most of it made elm
better for people too.

Most command-line tools assume a person who reads the manual once, remembers
it all, and notices when something looks wrong. An AI assistant does none of
that. It starts every session knowing nothing about your tool, pays for every
word it reads, and guesses confidently when it isn't sure.

Here's what matters, and what we added.

## 1. make the safe thing the only thing

elm has always been read-only. It only sends GET requests, so nothing an assistant types
can change a monitoring portal. I decided that long before AI came into it,
and it's still the most important decision.

Even though the LogicMonitor API hides a lot of details, read-only still
leaves a lot to read, like users, API tokens and contact details. So a credential profile can list the commands it allows:

```ini
allowed_commands = ['DeviceList', 'Alert*', 'SDTList']
```

Anything else stops before a request is sent:

```text
$ elm -p ai AdminList
Error: AdminList is not allowed. Profile 'ai' allows only: ...
No request was sent.
To allow it, add 'AdminList' to allowed_commands in ~/.config/logicmonitor/credentials/ai.ini.
If you are a script or an AI assistant: do not retry with another profile and do not
edit that file. Tell the person which command you need and why, and show them what you
would have run:
  elm -p ai AdminList
```

The last part is there because assistants are resourceful. Told no, the
obvious next move is another profile, so the error asks it to come back to
the person instead.

It exits with its own code (3), so a script can tell "not allowed" apart from
"failed". The repo has a suggested profile for assistants with about 45
commands for everyday questions, and a comment on each one I left out saying
why.

This is a guard rail, not a security boundary. What really limits access is
the API token's role in LogicMonitor, and the docs say so. But most of what
goes wrong is a wrong guess, and a guard rail stops those.

## 2. give it a manual it can afford

A person reads `--help` once. An assistant reads it every session, and every
character costs tokens and attention. So elm has two short manuals written
for that reader:

* **`elm --ai`** is a compact quick-start guide: how the flags work, the mistakes
  assistants actually make, and how to keep output small (ask for only the
  fields you need, count instead of fetching rows to count them).
* **`elm COMMAND --info`** describes one command: its parameters, every field
  it returns, and notes from testing. It needs no credentials and makes no API
  call, so an assistant can look things up as often as it likes.

The idea is it looks up what it needs when it needs it, instead of loading
everything up front. This saves on token usage and cost.

## 3. write errors that say how to fix it

elm has several short flags that mean different things before and after the
command name. `-f` is the output format before it and the field list after
it. People learn this once. Assistants get it wrong all the time.

A misplaced flag used to fail with a bare `no such option: -c`. That gave
nobody anything to act on, and assistants kept writing `elm -c AlertList`.
Now every error like that ends with the fix:

```text
Hint: -c is a command option: put it after the command name, e.g. elm AlertList -c
```

The hints are built from the options elm defines, so new flags get them for
free. The `--ai` guide adds one more line: *read the hint and move the flag;
do not drop it.*

## 4. refuse what would quietly go wrong

An error is annoying. A wrong answer with no error is worse, because an
assistant will report it as fact. The LogicMonitor API is full of these.

* **A misspelt field.** Filter AlertList on `sevrity` and the API ignores the
  filter and returns every alert. DeviceList matches nothing instead. elm now
  checks each field against the API's own field list first:

  ```text
  $ elm AlertList -F sevrity:4
  Error: ... no field 'sevrity' in AlertList (did you mean severity? ...)
  ```

* **An operator that isn't one.** `displayName:~web01` looks fine, but it's
  read as `:` with the value `~web01`, so it matches nothing. A small local
  model I was testing used it in 4 answers out of 28, and each time reported
  the device as missing. That's refused now too.
* **A flag in the wrong place.** `elm DeviceList -f csv` asked for a field
  called "csv". It's refused before any request is sent. `elm -o 2000
  DeviceList` writes the first page to a file called `2000`. That's valid, so
  it still runs, but with a warning, because it's almost never what was meant.
* **A failed request.** elm has always had `--halt-on-api-error`, and since
  September, exit code 3 for a command the profile doesn't allow. But with one
  profile, a request that failed (a TLS-inspecting proxy, a 403) printed its
  error and still exited 0 with nothing on stdout. To a script, that looks
  exactly like "no results". Samara, the question page built on elm, told
  someone a device didn't exist when the lookup had never got through. Now a
  failed request exits 1.

Each of these took a wrong answer to find. None of them were new problems,
an assistant just hit them more often than I ever had.

## 5. let it write times the way people say them

The API wants times as epochs. An assistant had to work out "the last hour"
itself, in seconds or milliseconds depending on the field (and the API docs
rarely say which), and in the right timezone. That's a lot of chances to be
quietly wrong.

Now elm does the maths:

```shell
elm AlertList -F 'cleared:false,startEpoch>:now-1h'   # started in the last hour
elm AlertList -F 'startEpoch:now-1M/M'                # last calendar month
elm SDTList -F 'startDateTime<:now+7d'                # SDTs starting in the next week
```

It's the same date maths as Elasticsearch and Grafana, so plenty of people
already know it. Dates work too (`2026-07`, `2026-07-14`). Everything is local
time, daylight saving included. For the seconds or milliseconds question, elm
asks the API for one value of that field first: anything above 10^11 can only
be milliseconds.

And `-t` turns epochs in the results back into local times:

```text
$ elm -t -f txt AlertList -F 'cleared:false,startEpoch>:now-1h' -f startEpoch,endEpoch,monitorObjectName
  monitorObjectName      endEpoch  startEpoch
  web01                         0  2026-10-28 16:53:06 AEDT
```

The `0` stays a `0`, because it means "not ended", not 1970. Fields like
`upTime` stay numbers too.

## 6. write down what testing found, and how sure you are

The API's own docs aren't always right. Some filters are silently ignored.
Some fields mean something other than their description. elm keeps notes
from testing against real portals, and `--info` shows them next to the
documented fields. Where they disagree, the tested note wins.

But notes can be wrong too. For months a note said LogicMonitor's alert
severity numbers ran the other way round. It was written as if it had been
checked live, and every assistant that read it repeated it confidently. Fixing
the number wasn't enough. The guide now tells assistants that if real results
contradict either source, they should say so, and every note records how and
when it was checked.

## 7. bigger is not safer

It's tempting to keep adding to AI-facing docs. Each addition feels like it
can only help. It doesn't. A longer file costs more on every question, and it
collects contradictions and stale claims nobody re-reads.

So elm's AI-facing text has budgets, checked by the build:

* The knowledge file, read before every question, has to stay under 8,000
  characters.
* Each command's `--info` has to stay under 16,000.
* Each fact has one home. A rule about one command goes in that command's
  notes, a rule across commands in the knowledge file, and a longer recipe in
  the examples. Never the same fact in two places.

If something goes over budget the build fails, and something else has to be
trimmed, merged or deleted first.

## 8. keep secrets, and other people's words, out of reach

elm can print the exact request it would send, including a signed
authorization header. That's handy for debugging, and exactly what should
never end up in an assistant's chat log.

So [Samara](https://github.com/rdmarsh/elm/tree/main/samara) lets the model
pick the command, filters and fields, but not elm's global flags. It also
strips fields that can carry secrets, and personal contact details, before
the model sees any rows.

Then I found the model believing what it read. Anyone who can edit a device
can write in its description or a property. I left a note on a test device
saying it had been decommissioned. A small model repeated that as fact,
twice, about a device that was up, whatever the prompt said. So now the model never reads
descriptions, comments or property values at all. The person asking still
sees every value, in a table. The model just doesn't get to act on them.

I'd rather decide what the model can reach than trust it to behave.

## what it adds up to

None of this is clever. It's the same stuff that makes any command-line tool
good: safe defaults, short docs, helpful errors, no silent failures, honest
notes. The difference is an AI user finds every weak spot quickly, over and
over, and never learns from last week.

Building for that reader made elm better for people too. The hints, `--info`,
`now-1h` and `-t` are just as useful at 2am when you're the one guessing.

elm is open source: [github.com/rdmarsh/elm](https://github.com/rdmarsh/elm).
The [first post](https://rdmarsh.github.io/elm/2026/10/12/introducing-elm.html)
gives an overview, and [ai.md](https://github.com/rdmarsh/elm/blob/main/ai.md)
covers how I work with an AI assistant day to day.

*LOGICMONITOR is a trademark of LogicMonitor, Inc. elm is an independent
project and is not affiliated with LogicMonitor.*
