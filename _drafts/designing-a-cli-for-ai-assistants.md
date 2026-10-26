---
layout: default
title: "designing a cli for ai assistants (who never read the manual)"
---

tldr; More and more commands in a terminal are typed by an AI assistant, not
a person. I changed [elm](https://github.com/rdmarsh/elm), my command-line
tool for LogicMonitor, to suit that: safe by default, short docs it can afford
to read, errors that say how to fix the mistake, and notes that say how sure
they are. Most of it made elm better for people too.

Most command-line tools assume a person who reads the manual once, remembers
it, and notices when something looks wrong. An AI assistant does none of
that. It starts every session knowing nothing about your tool, pays for every
word it reads, and guesses confidently when it isn't sure.

Here's what I changed.

## 1. make the safe thing the only thing

elm is read-only. It only sends GET requests, so nothing an assistant types
can change a monitoring portal. I decided that long before AI came into it,
and it's still the most important decision.

Read-only still leaves a lot to read, like users, API tokens and contact
details. So a credential profile can list the commands it allows:

```ini
allowed_commands = ['DeviceList', 'Alert*', 'SDTList']
```

Anything else stops before a request is sent:

```text
$ elm -p ai AdminList
Error: AdminList is not allowed. Profile 'ai' allows only: ...
No request was sent.
```

The error names the command, says nothing was sent, and gives the line to add
if it should be allowed. It exits with its own code (3), so a script can tell
"not allowed" apart from "failed". The repo has a suggested profile for
assistants with 39 commands for everyday questions, and a comment on each one
I left out explaining why.

This is a guard rail, not a security boundary. What really limits access is
the API token's role in LogicMonitor, and the docs say so. But most of what
goes wrong is a wrong guess, and a guard rail stops those.

## 2. give it a manual it can afford

A person reads `--help` once. An assistant reads it every session, and every
character costs tokens and attention. So elm has two short manuals written
for that reader:

* **`elm --ai`** is a quick-start guide: how the flags work, the mistakes
  assistants actually make, and how to keep output small (ask for only the
  fields you need, count instead of fetching rows to count them).
* **`elm COMMAND --info`** describes one command: its parameters, every field
  it returns, and notes from testing. It needs no credentials and makes no API
  call, so an assistant can look things up as often as it likes.

The idea is it looks up what it needs when it needs it, instead of loading
everything up front.

## 3. write errors that say how to fix it

elm has three short flags that mean different things before and after the
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

Two mix-ups used to run without any error at all, which is the worst kind.
`elm DeviceList -f csv` asked for a field called "csv". That's now refused
before any request is sent. `elm -o 2000 DeviceList` writes the first page to
a file called `2000`. That's valid, so it still runs, but with a warning,
because it's almost never what was meant.

## 4. write down what testing found, and how sure you are

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

## 5. bigger is not safer

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

## 6. keep secrets out of reach

elm can print the exact request it would send, including a signed
authorization header. That's handy for debugging, and exactly what should
never end up in an assistant's chat log.

So [Samara](https://github.com/rdmarsh/elm/tree/main/samara), the
plain-English question page built on elm, lets the model pick the command,
filters and fields, but not elm's global flags. Before the model sees any
rows, it also strips fields that can carry secrets, and personal contact
details. I'd rather decide what the model can reach than trust it to behave.

## what it adds up to

None of this is clever. It's the same stuff that makes any command-line tool
good: safe defaults, short docs, helpful errors, honest notes. The difference
is an AI user finds every weak spot quickly, over and over, and never learns
from last week.

Building for that reader made elm better for people too. The hints, `--info`
and the shorter docs are just as useful at 2am when you're the one guessing.

elm is open source: [github.com/rdmarsh/elm](https://github.com/rdmarsh/elm).
The [first post](https://rdmarsh.github.io/elm/2026/10/12/introducing-elm.html)
gives an overview, and [ai.md](https://github.com/rdmarsh/elm/blob/main/ai.md)
covers how I work with an AI assistant day to day.

*LOGICMONITOR is a trademark of LogicMonitor, Inc. elm is an independent
project and is not affiliated with LogicMonitor.*
