---
layout: default
title: "Designing a CLI for AI assistants"
---

More and more of the commands typed into a terminal are typed by an AI
assistant. Most command-line tools were designed for a person who reads the
manual once, remembers it, and notices when something looks wrong. An AI
assistant does none of those things. It starts each session knowing nothing
about your tool, pays for every word it reads, and confidently guesses when it
is unsure.

[elm](https://github.com/rdmarsh/elm), my command-line tool for LogicMonitor,
now has both kinds of user. This post covers what I changed for the second
kind, and why most of it helped the first kind too.

## 1. Make the safe thing the only thing

elm is read-only. It only sends GET requests, so nothing an assistant types
can change a monitoring portal. That was a design decision long before AI
came into it, and it is still the most important one. You can't prompt your
way past a capability that does not exist.

Read-only still leaves a lot to read: users, API tokens, contact details. So a
credential profile can list the commands it allows:

```ini
allowed_commands = ['DeviceList', 'Alert*', 'SDTList']
```

Anything else stops before a request is sent:

```text
$ elm -p ai AdminList
Error: AdminList is not allowed. Profile 'ai' allows only: ...
No request was sent.
```

The error names the command that was tried, says plainly that nothing was
sent, and gives the line to add if it should be allowed. It exits with its own
code (3), so a script can tell "not allowed" apart from "failed". The repo
ships a suggested profile for assistants: 44 commands for everyday questions,
with comments explaining each one that was left out.

This is a guard rail, not a security boundary. What really limits access is
the API token's role in LogicMonitor, and the documentation says so. A guard
rail stops wrong guesses, and wrong guesses are most of what goes wrong.

## 2. Give the model a manual it can afford

A person reads `--help` once. An assistant reads it in every session, and
every character costs tokens and attention. So elm has two short manuals
written for that reader:

- **`elm --ai`** is a quick-start guide: how the flags work, the mistakes
  assistants actually make, and how to keep output small (ask for only the
  fields you need, count instead of fetching rows to count them, prefer
  compact formats).
- **`elm COMMAND --info`** describes one command: its parameters, every field
  it returns, and notes from testing. It needs no credentials and makes no API
  call, so an assistant can look things up as often as it likes.

The goal is that the assistant looks up what it needs, when it needs it,
instead of loading everything up front.

## 3. Write errors that teach

elm has three short flags that mean different things before and after the
command name. `-f` is the output format before it and the field list after
it. People learn this once. Assistants get it wrong regularly.

A misplaced flag used to fail with a bare `no such option: -c`. That gave a
person or an assistant nothing to act on, and assistants kept writing
`elm -c AlertList`. Now every such error ends with the fix:

```text
Hint: -c is a command option: put it after the command name, e.g. elm AlertList -c
```

The hints are built from the options elm defines, so new flags get them
automatically. The `--ai` guide adds one more line: *read the hint and move
the flag; do not drop it.*

Two mix-ups used to run without any error at all, and they were the worst
kind. `elm DeviceList -f csv` asked for a field called "csv". It is now refused
before any request is sent. `elm -o 2000 DeviceList` writes the first page to
a file called `2000`. That is valid syntax, so it still runs, but with a
warning, because it is almost never what was meant.

## 4. Record what testing found, and say how sure you are

The API's own documentation is not always right. Some filters are silently
ignored. Some fields mean something other than their description. elm keeps
notes from testing against real portals, and `--info` shows them next to the
documented fields, with a rule: where they disagree, prefer the tested note.

But notes can be wrong too. For months, a note said LogicMonitor's alert
severity numbers ran the other way round. It was written as if it had been
checked live, and every assistant that read it repeated it confidently. The
fix wasn't just correcting the number. The guide now tells assistants that if
real results contradict either source, they should say so. And every note
records how and when it was verified.

## 5. Bigger is not safer

The temptation with AI-facing documentation is to keep adding to it. Each
addition feels like it can only help. It doesn't. A longer file costs more on
every question, and it collects contradictions and stale claims that nobody
re-reads.

So elm's AI-facing text has budgets, checked by the build:

- The cross-command knowledge file, read before every question, must stay
  under 8,000 characters.
- Each command's `--info` must stay under 16,000.
- Each fact has one home. A rule about one command goes in that command's
  notes, a rule across commands in the knowledge file, and a longer recipe in
  the examples. Never the same fact in two places.

If an addition goes over budget, the build fails. Something else has to be
trimmed, merged or deleted first.

## 6. Keep secrets out of reach

elm can print the exact request it would send, including a signed
authorization header, which is useful for debugging. That is exactly what
should never end up in an assistant's chat log. So
[elm-ask](https://github.com/rdmarsh/elm/tree/main/samara), the
plain-English question prototype, lets the model choose the command, filters
and fields, but not elm's global flags. Before the model sees any rows, it
also strips fields that can carry secrets, along with personal contact
details.

The principle: decide what the model can reach, not just what it should do.

## What it adds up to

None of this is clever. It is the same craft as any good command-line tool:
safe defaults, short docs, helpful errors, honest notes. The difference is
that an AI user exposes every weak spot quickly and at scale, and never
learns from last week.

Designing for that reader made elm better for people too. The hints, `--info`
and the shorter docs are just as useful at 2 a.m. when you are the one
guessing.

elm is open source: [github.com/rdmarsh/elm](https://github.com/rdmarsh/elm).
The [first post](https://rdmarsh.github.io/elm/2026/10/12/introducing-elm.html)
gives an overview, and [ai.md](https://github.com/rdmarsh/elm/blob/main/ai.md)
covers how I work with an AI assistant day to day.

*LOGICMONITOR is a trademark of LogicMonitor, Inc. elm is an independent
project and is not affiliated with LogicMonitor.*
