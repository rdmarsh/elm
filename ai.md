# AI-Assisted Development Workflow

AI tools are useful, but only when treated like fast junior engineers with unlimited energy and limited judgement.

The quality of the output depends heavily on:
- project documentation
- clear rules
- tight feedback loops
- small scoped tasks
- verification at every step

## Core principles

### 1. Keep project knowledge in files

Do not rely on chat history as memory.

Every project should contain:
- design documents
- architecture notes
- coding standards
- workflow rules
- progress journals
- TODO tracking

The AI should read these files at the start of every session.

Prefer Markdown files committed to the repository so both humans and AI share the same source of truth.

---

### 2. Structure memory by type

A single journal file conflates different kinds of information and becomes noise over time.

Separate memory by type:

- **User context** — who is working on this, their expertise, what they care about. Helps calibrate explanation depth and framing.
- **Feedback** — corrections and confirmations, each with a *why*. Record both directions: if you only save corrections, you avoid past mistakes but drift away from approaches that were already validated. The *why* lets edge cases be judged rather than rules applied blindly.
- **Project state** — current goals, blockers, parked ideas, open questions, deadlines.
- **References** — where to find things: dashboards, issue trackers, external docs, external credentials or configuration.

Keep these in separate files. Load only what is relevant to the current session.

---

### 3. Describe desired behaviour positively

Write rules describing how work should be done rather than only listing forbidden behaviour.

Good:
- "Preserve existing debug logging unless explicitly asked to remove it."
- "Implement changes incrementally and verify after each step."

Bad:
- "Don't remove logs."
- "Don't break things."

Positive instructions produce more reliable behaviour.

---

### 4. Separate design from implementation

Maintain design documents describing:
- architecture
- intended workflows
- module responsibilities
- invariants
- interfaces
- constraints

Then instruct the AI to implement the documented design.

If implementation repeatedly goes wrong:
1. improve the design docs
2. improve the rules
3. review whether the architecture itself is unclear

Do not keep patching prompts forever.

---

### 5. Use minimal prompts

Once project context exists in files:
- prompts should be short
- prompts should reference TODO items
- prompts should focus on one task at a time

Long conversational prompting usually causes drift and inconsistency.

Define named shorthands for repeatable multi-step sequences. Document the expansion in project rules so the AI learns it rather than guessing.

Good:
- "wrap it up" → check for leaks, update changelog, update docs, commit, push, update journal

This is more reliable than re-stating the full sequence each time.

---

### 6. Use isolated sessions

Prefer a new AI session for each feature or task.

This reduces:
- context pollution
- stale assumptions
- accidental behavioural drift

Persistent project files should carry the long-term memory instead.

---

### 7. Prefer incremental changes

Avoid large speculative rewrites.

Make:
- small changes
- verify behaviour
- review output
- continue iteratively

Large unverified refactors are where AI tools fail hardest.

---

### 8. Use test-driven development where practical

Preferred workflow:
1. write failing test/check
2. confirm failure occurs for expected reason
3. implement fix
4. confirm passing result
5. refactor if needed

Do not generate tests and implementation simultaneously and call it TDD.

---

### 9. Treat mistakes as process failures

When the AI makes a mistake:
1. fix the code
2. identify why the mistake happened
3. improve rules or design docs if needed
4. record lessons learned in the project journal

The goal is not merely fixing bugs.

The goal is improving the system that produced them.

---

### 10. Prefer simple, readable code

Write the simplest code that correctly solves the problem.

- Readable and explicit beats clever and compact.
- A future reader — or the same person at 3am — should understand the code without reverse-engineering it.
- If a solution surprised you when you wrote it, it will surprise the next reader too.
- Three clear lines beat one clever expression.
- Avoid unnecessary abstraction, indirection, and generality.

AI tools tend toward impressive-looking solutions. Push back on complexity that is not earned by the problem.

---

# Recommended AI Behaviour Rules

## General behaviour

Be direct, technically honest, and precise.

- Say when something is wrong.
- Explain why an approach is risky or poorly designed.
- Push back on questionable changes before implementing them.
- Distinguish facts from assumptions.
- Explain tradeoffs instead of presenting guesses as certainty.
- Prefer correctness over agreement.

Avoid:
- flattery
- validation phrases ("great question", "you're absolutely right")
- pretending confidence where uncertainty exists

A thirty-second argument before implementing is better than chasing a bad change afterward.

If uncertain:
- state the uncertainty
- explain what information is missing
- suggest ways to verify

---

## Working with code

Preserve intentional diagnostics and documentation.

- Keep existing comments, debug output, and logging unless removal is explicitly requested.
- Improve comments and logging when useful, but explain what changed and why.
- If a comment, log line, or debug statement should be removed, say so and let the author decide.
- Avoid speculative refactors unrelated to the task.
- Prefer minimal, reviewable diffs.
- Write the simplest code that solves the problem. Avoid clever solutions when a straightforward one exists.

Before making architectural changes:
- explain the reasoning
- explain tradeoffs
- identify risks
- confirm assumptions against existing design docs

### Generated files

If any files are generated artefacts — from templates, build pipelines, or code generators — document this prominently.

- Do not edit generated files directly.
- Fixes belong in the template source, not the generated output.
- The AI will edit whatever file it can find unless explicitly told otherwise.

Document which files are generated and what produces them, in CLAUDE.md or equivalent.

---

## Verification and testing

After each meaningful change:
- run tests
- run linters/checks where available
- verify expected behaviour
- report failures clearly

AI tools will confidently cite library methods, function signatures, and config options that do not exist. Running the code is what catches this — static review is not sufficient, because a hallucinated method name is syntactically indistinguishable from a real one.

Do not claim something works without verification.

If verification cannot be performed:
- say so explicitly
- explain what remains unverified

---

## Scope of authorisation

Approving one action does not authorise the same action in a different context.

Confirm risky or irreversible operations explicitly each time:
- pushing to a remote
- dropping or overwriting data
- force operations
- modifying shared infrastructure

Unless standing permission is recorded in a durable config file that both the human and the AI can read, do not assume prior approval carries forward.

---

## Project journal workflow

Maintain a `journal.md` containing:
- recent work
- parked ideas
- open questions
- lessons learned

Update it whenever:
- significant work completes
- mistakes reveal missing rules
- architectural decisions change
- work is deferred

The journal is operational memory, not a changelog.

Summarise outcomes and reasoning, not every tiny edit.

---

## Session startup

At the start of each session:
1. Read the journal.
2. Check parked ideas and open questions.
3. Note current project state before asking or being asked what to work on.

Do not rely on the AI to remember previous sessions. Assume a cold start every time and let the files provide continuity.

---

## Recommended project structure

```text
project/
├── CLAUDE.md
├── journal.md
├── memory/
│   ├── user.md
│   ├── feedback.md
│   ├── project.md
│   └── references.md
├── docs/
│   ├── architecture.md
│   ├── design.md
│   ├── workflows.md
│   └── coding-standards.md
├── todo.md
└── src/
```

---

# Short Operational Prompt

Once the project is structured properly, prompts can stay extremely small:

```text
Read the project docs and journal.
Complete the highest priority TODO item.
Use TDD.
Update journal.md if new lessons or decisions emerge.
```

Most people are still trying to "prompt engineer" around missing project structure.

The structure matters far more than clever prompts.
