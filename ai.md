# AI-Assisted Development Workflow

Treat AI tools as fast junior engineers: unlimited energy, limited judgement.
Output quality depends on project documentation, clear rules, tight feedback
loops, narrowly scoped tasks, and verification at every step. Most failed
AI-assisted work is a documentation and process failure, not a prompt failure.

# Principles

## Keep project knowledge in files

Chat history is temporary; Markdown committed to the repository is the
long-term memory both humans and AI share. Keep design and architecture notes,
coding standards, workflow rules, a journal, and TODO tracking, and have the AI
read them at the start of every session.

Separate memory by type, in separate files, and load only what the task needs:

- **User context** - who works on the project, their expertise, constraints and priorities.
- **Feedback** - corrections *and* confirmed approaches, each with a *why*.
  Saving only mistakes loses the patterns already validated.
- **Project state** - goals, blockers, parked ideas, open questions, deadlines.
- **References** - dashboards, trackers, runbooks, non-sensitive config locations.

Never store secrets or credentials in AI-readable memory.

### Preserve information before condensing it

Before deleting, merging or shortening notes, classify each item and move it
to its proper home first: work to the backlog, evidence and lessons to the
journal or design notes, user-visible changes to the changelog, rejected ideas
(with their reasoning) to an explicit decision. If unsure, keep the original or
ask. A shorter file that loses future work, evidence, reasoning, open questions
or rejected alternatives is not an improvement.

## Write rules positively

Say how work should be done ("Preserve existing debug logging unless asked to
remove it") rather than only what is forbidden ("Don't remove logs"). Keep
negative constraints for security boundaries and destructive or irreversible
actions.

## Separate design from implementation

Document architecture, workflows, module responsibilities, invariants,
interfaces and constraints, then have the AI implement the documented design.
If implementation keeps going wrong, improve the design docs and rules, or
question the architecture - repeated prompting means something is
underspecified. Fix the system, not the prompt.

## Short prompts, short sessions

With context in files, prompts can be short, reference a TODO item, and cover
one task. Define named shorthands for repeated sequences and document their
expansion, e.g. "wrap it up" -> check for leaks, update changelog and docs,
commit, push, update journal.

Start a new session per feature or task. Long sessions accumulate stale
assumptions, conflicting context and drift; the files carry continuity.

## Small, verified steps

Prefer small changes with reviewable diffs over speculative rewrites. Small
steps are easier to review, revert, debug and attribute; large unverified
refactors are where AI fails hardest.

Use TDD where practical: write a failing test, confirm it fails for the right
reason, implement, confirm it passes, refactor. Writing tests and
implementation together is not TDD. Test observable behaviour and edge cases,
not a mirror of the implementation.

## Treat mistakes as process failures

Fix the code, find why it happened, improve the rules or docs, restore anything
wrongly deleted or compressed, record the lesson in the journal, and tell the
user what changed. Repeated classes of mistake call for stronger rules or
better verification.

## Simple, consistent code

Write the simplest code that correctly solves the problem: explicit over
clever, three clear lines over one clever expression, no unearned abstraction.
If a solution surprised you, it will surprise the next reader. Prefer the
codebase's existing patterns, and extend existing systems rather than adding
parallel helpers or wrappers - AI tends to add redundant abstractions because
it optimises for finishing now. Optimise for the future maintainer:
correctness and clarity over speed.

## Understand before modifying

Read the surrounding code, its invariants and conventions, and why it exists
before changing it. Awkward code may reflect operational constraints,
compatibility, historical bugs, performance, or external interfaces.

## Instruction precedence

1. Explicit user request in the current session
2. Security and safety constraints
3. Architecture and design documents
4. Project rules (`CLAUDE.md`)
5. Inline comments and local conventions
6. TODO items and journals
7. Historical decisions in memory files

If a conflict remains, stop, explain it, and ask. Do not guess.

## Stop and ask when

Requirements conflict, data could be lost, behaviour is ambiguous, security
implications are unclear, architectural intent can't be inferred, or
reasonable options differ materially in tradeoffs.

# AI behaviour rules

## General

Be direct and technically honest. Say when something is wrong and why, push
back before implementing questionable changes, separate facts from
assumptions, and explain tradeoffs. No flattery, no simulated certainty: if
unsure, say what is missing and how to verify it. A thirty-second argument
beats chasing a bad change afterward.

## Working with code

- Keep existing comments, debug output and logging unless asked; if something
  should go, say so and let the author decide.
- Keep scope tight: no speculative refactors, formatting churn or unexplained
  renames; record unrelated issues separately instead of silently fixing them.
- Match surrounding style.
- Before architectural changes, explain reasoning, tradeoffs and risks, and
  check assumptions against the design docs.
- Avoid reproducing verbatim code from known licensed sources; in commercial
  work, flag output that closely resembles a specific library.

## Verify, don't assume

APIs, methods, config options, package names and remembered examples may not
exist or may be out of date. Check against official docs, existing project
usage, installed versions and actual runtime behaviour - plausible code is not
evidence, and a hallucinated method name looks exactly like a real one.

After each meaningful change, run the tests, linters and checks, and report
failures. Never claim something works without verifying it; if you can't,
say what remains unverified and how to check it.

Documentation examples of program output (tables, CLI sessions, JSON,
reports) must come from running the program, never from memory. Keep the input
that produced each example nearby and regenerate it when the format changes.

## Generated files

Document prominently (in `CLAUDE.md`) which files are generated, what produces
them, and how to regenerate them. Fix the template, never the output - an AI
will edit whatever file it finds unless told otherwise.

## Sensitive data

Anything sent to an AI service may be logged, retained or used for training.
Replace real account names, hostnames, IPs and usernames with placeholders;
never paste credentials, keys or tokens; sanitise logs and API responses, or
describe their structure instead. Use the same documented placeholders across
examples, issues, docs and test fixtures.

## Security review

AI-generated code can contain hardcoded secrets, command injection from string
concatenation, missing input validation at boundaries, insecure defaults, and
invented or malicious packages. Review for these before accepting; passing
tests are not evidence of safety. Before adding a suggested dependency, check
that it exists, is maintained, and has no known CVEs.

Review AI-contributed code again when a significant feature completes and when
dependencies change - also for committed credentials and needless
dependencies - and record what was checked, found and fixed in the journal.

## Scope of authorisation

Approving an action once does not approve it elsewhere. Confirm risky or
irreversible operations every time (pushing, overwriting or dropping data,
force operations, shared infrastructure) unless standing permission is
recorded in a file both human and AI can read. When suggesting a shell
command, explain it and flag anything destructive.

## Journal

Keep a `journal.md` of recent work, parked ideas, open questions and lessons.
Update it when significant work completes, mistakes reveal missing rules,
decisions change, or work is deferred. Record reasoning - why, what was
rejected, what is uncertain - not every edit. It is operational memory, not a
changelog.

For non-obvious constants, timeouts, retries, thresholds and workarounds,
record the observed problem, the evidence, what was tested, why that value was
chosen, and what risk remains. Keep code comments short but make the reasoning
traceable. Behaviour without preserved reasoning becomes superstition.

## Session startup

Assume a cold start: read the journal, check parked ideas and open questions,
and note the current state before starting work.

# Recommended structure

```text
project/
├── CLAUDE.md
├── journal.md
├── todo.md
├── memory/        user.md, feedback.md, project.md, references.md
├── docs/          architecture.md, design.md, workflows.md, coding-standards.md,
│                  ai-workflow.md, ai-rules.md, ai-security.md, project-memory.md
└── src/
```

With that in place, a working prompt can be this small:

```text
Read the project docs and journal.
Complete the highest priority TODO item.
Use TDD where practical.
Update journal.md if new lessons, decisions, or operational knowledge emerge.
```
