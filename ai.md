# Working with an AI assistant

tldr; Treat an AI assistant as a fast junior engineer: lots of energy, not
much judgement, and no memory of yesterday. What it produces depends more on
the docs, rules and checks around it than on the prompt. When it keeps
getting something wrong, fix the docs or the process, not the prompt.

This is how I work on elm with Claude Code. Most of it applies to any project
and any assistant.

## Keep what it needs to know in files

Chat history is gone when the session ends. Files are the memory we share,
so the assistant reads them at the start of every session.

* **`CLAUDE.md`** is loaded every session. Only what holds everywhere: what
  never to do ("never edit generated files"), which files are generated and
  how to rebuild them, gotchas the code can't show.
* **A subdirectory's `CLAUDE.md`, or a rule in `.claude/rules/` with
  `paths:`**, loads only when working on those files. elm's rule for its
  AI-facing docs loads only when one of them is being edited.
* **Skills** (`.claude/skills/NAME/SKILL.md`) load only a one-line
  description; the rest loads when the task comes up. Anything repeatable
  but done rarely belongs in one: it costs a line until it's needed, and the
  steps are written down for when I've forgotten them. elm has `release` (cut
  a version). Personal skills, like one for writing in my voice, stay out of
  the repo (`.git/info/exclude`). `--help` and `elm COMMAND --info` work the
  same way.
* **Memory** is one fact per file, by type: who I am, feedback (corrections
  *and* approaches that worked, each with why), project state, and
  references. Saving only mistakes loses what already works.
* **`todo.md` and `CHANGELOG.md`** hold deferred work and what changed for
  users.

Leave out what a session can work out itself: the directory layout,
dependency lists, standard commands, API details in the source. Give each
fact one home, because a copy in a second file goes stale.

Everything loaded every session costs tokens every time, and a big file
collects stale claims nobody re-reads. Bigger is not safer.

Run `/doctor` in Claude Code now and then. It checks the install and
settings and points out problems.

Never put secrets in anything an assistant reads.

**Before shortening a file**, move each item to its proper home first: work
to `todo.md`, lessons to memory or the design notes, user-visible changes to
the changelog, rejected ideas (with the reason) to a written decision. If
unsure, keep it or ask. A shorter file that loses work, evidence, reasoning
or open questions is not an improvement.

## Short prompts, short sessions, small steps

With the context in files, a prompt can be one line about one task. Name
repeated sequences and write down what they mean: "wrap it up" means check
for leaks, update the changelog and docs, commit and push.

Start a new session per task. Long sessions pile up stale assumptions and
drift; the files carry what matters.

Small changes with diffs I can review beat big rewrites. Big unverified
refactors are where AI fails hardest.

Use TDD where it fits: write a failing test, check it fails for the right
reason, then make it pass. Tests and code written together isn't TDD. Test
behaviour and edge cases, not a copy of the implementation.

## Design first

Write down the architecture, invariants and interfaces, then have the
assistant build to that. If it keeps going wrong, the design is
underspecified or wrong. Fix the system, not the prompt.

Write rules as what to do ("keep existing debug logging unless asked"), and
keep "never" for security and things that can't be undone.

## Rules for the assistant

* **Be honest.** Say when something is wrong and why, and push back before
  building a bad idea. Separate facts from guesses. No flattery and no fake
  certainty: if unsure, say what's missing and how to check. A thirty-second
  argument beats undoing a bad change.
* **Understand before changing.** Read the code around it and why it's
  there. Awkward code often has a reason: compatibility, an old bug,
  performance, an outside system.
* **Keep it simple.** Explicit over clever, three clear lines over one
  clever one, no abstraction it hasn't earned. Use the patterns already in
  the code and extend what's there instead of adding a parallel helper.
  Assistants add those because they want to finish now; write for the next
  person to read it.
* **Keep scope tight.** Keep existing comments and logging unless asked. No
  speculative refactors, reformatting or renames. Note unrelated problems
  instead of quietly fixing them. Match the style around it.
* **Explain big changes first**: the reasoning, tradeoffs and risks, checked
  against the design notes.
* **Verify, don't assume.** APIs, options and package names it remembers may
  not exist, and a made-up method name looks exactly like a real one. Check
  the docs, the installed version and what actually runs. Run the tests
  after each change and report failures. If something wasn't verified, say
  so and how to check it.
* **Example output comes from running the program**, never from memory. Keep
  the input next to it so it can be regenerated. Notes say how and when they
  were checked: one of elm's was marked "verified live" and was backwards for
  months.
* **Fix the template, not the output.** Say in `CLAUDE.md` which files are
  generated, because an assistant edits whatever file it finds.
* **Approval doesn't carry over.** Confirm risky or irreversible actions
  every time (push, overwrite, delete, force, shared systems) unless
  standing permission is written down. Explain any shell command it
  suggests, and flag anything destructive.
* **Stop and ask** when requirements conflict, data could be lost,
  behaviour or intent is unclear, the security impact is unclear, or the
  options differ in ways that matter.

When instructions conflict, this order wins: my request now, security and
safety, design docs, `CLAUDE.md`, local comments and conventions, `todo.md`,
then old decisions in memory. If it's still unclear, stop and ask.

## When it makes a mistake

Treat it as a process failure. Fix the code, find why it happened, fix the
rule or doc that let it happen, restore anything wrongly deleted, save the
lesson, and say what changed. The same kind of mistake twice needs a
stronger rule or a better check.

For odd constants, timeouts, retries and workarounds, write down the problem,
the evidence, what was tested, why that value, and what risk is left.
Behaviour without the reason behind it turns into superstition.

## Sensitive data and security

Anything sent to an AI service may be logged or kept. Use placeholders for
real account names, hostnames, IPs and usernames, and the same ones
everywhere (elm uses `portal01`, `web01`, `lm01`). Never paste credentials or
tokens. Sanitise logs and API responses, or describe their shape instead.

Review AI code for hardcoded secrets, command injection from building
strings, missing input checks, insecure defaults, and made-up or malicious
packages. Passing tests don't prove it's safe. Before adding a dependency,
check it exists, is maintained and has no known CVEs. Review again when a
big feature lands or dependencies change. Don't copy code from licensed
sources word for word.

Limit what the assistant can reach, not just what it's told. elm is
read-only, the assistant runs in a sandbox, and its LogicMonitor profile
allows only the commands it needs.

## Starting a session

Assume it knows nothing. With the above in place, a prompt can be this
small:

```text
Read CLAUDE.md and todo.md.
Do the highest priority item.
Use TDD where it fits.
Save anything new we learnt.
```
