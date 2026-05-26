# AI-Assisted Development Workflow

AI tools are useful, but only when treated like fast junior engineers with unlimited energy and limited judgement.

The quality of the output depends heavily on:
- project documentation
- clear rules
- tight feedback loops
- narrowly scoped tasks
- verification at every step

# Core principles

## Keep project knowledge in files

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

Treat project files as the authoritative long-term memory of the project. Conversations are temporary working context only.

## Structure memory by type

A single journal file conflates different kinds of information and becomes noise over time.

Separate memory by type:

- **User context** - who is working on the project, their expertise, constraints, and priorities. This helps calibrate explanation depth and implementation style.
- **Feedback** - corrections and confirmations, each with a *why*. Record both positive and negative outcomes. Saving only mistakes prevents repetition, but saving successful patterns preserves approaches already validated.
- **Project state** - current goals, blockers, parked ideas, open questions, deadlines, and active investigations.
- **References** - dashboards, issue trackers, documentation, operational runbooks, and non-sensitive configuration locations.

Keep these in separate files. Load only what is relevant to the current task or session.

Secrets and credentials should never be stored in AI-readable project memory.

### Preserve information before condensing it

Backlogs, journals, investigation notes, and changelogs serve different purposes. Cleaning one up must not silently discard information that has not yet been classified.

Before deleting, consolidating, or substantially shortening project notes:

1. Identify each distinct item, decision, or observation.
2. Decide its proper destination:
   - active or deferred work belongs in backlog or TODO tracking
   - investigation evidence and lessons learned belong in the project journal or design notes
   - completed user-visible changes belong in the changelog
   - rejected ideas should be retained as explicit decisions when the reasoning may matter later
3. Move or summarise the information in its destination before removing the original detail.
4. Preserve the original material if classification is uncertain, or ask before deleting it.

Do not silently compress away:
- future work
- operational evidence
- design reasoning
- unresolved questions
- rejected alternatives that may later become relevant again

A shorter file is not an improvement if it loses knowledge.

## Describe desired behaviour positively

Write rules describing how work should be done rather than only listing forbidden behaviour.

Good:
- "Preserve existing debug logging unless explicitly asked to remove it."
- "Implement changes incrementally and verify after each step."

Bad:
- "Don't remove logs."
- "Don't break things."

Positive instructions usually produce more reliable behaviour.

Negative constraints are still important for:
- security boundaries
- destructive operations
- irreversible actions

Use both styles where appropriate.

## Separate design from implementation

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

Repeated prompting is usually evidence that:
- the design is underspecified
- project rules are incomplete
- expectations are implicit instead of documented

Fix the system, not just the prompt.

## Use minimal prompts

Once project context exists in files:
- prompts should be short
- prompts should reference TODO items
- prompts should focus on one task at a time

Long conversational prompting usually causes drift, inconsistency, and stale assumptions.

Define named shorthands for repeatable multi-step sequences. Document the expansion in project rules so the AI learns it rather than guessing.

Good:
- "wrap it up" -> check for leaks, update changelog, update docs, commit, push, update journal

This is more reliable than re-stating the full sequence each time.

## Use isolated sessions

Prefer a new AI session for each feature or task.

This reduces:
- context pollution
- stale assumptions
- accidental behavioural drift

Long sessions accumulate stale assumptions, conflicting context, and behavioural drift.

Keep sessions short and let project files carry continuity instead.

Persistent project files should carry the long-term memory.

## Prefer incremental changes

Avoid large speculative rewrites.

Prefer:
- small changes
- explicit verification
- reviewable diffs
- iterative progress

Large unverified refactors are where AI tools fail hardest.

Small validated steps are easier to:
- review
- revert
- reason about
- debug
- attribute

## Use test-driven development where practical

Preferred workflow:
1. write a failing test or check
2. confirm the failure occurs for the expected reason
3. implement the fix
4. confirm the result passes
5. refactor if needed

Do not generate tests and implementation simultaneously and call it TDD.

Tests should validate externally observable behaviour and important edge cases, not merely mirror the implementation.

A weak test that only confirms the generated implementation behaves as written is not meaningful verification.

## Treat mistakes as process failures

When the AI makes a mistake:
1. fix the code
2. identify why the mistake happened
3. improve rules or design docs if needed
4. restore or relocate any information incorrectly deleted, overwritten, or compressed
5. record lessons learned in the project journal
6. tell the user what was corrected and what rule or documentation changed

The goal is not merely fixing bugs.

The goal is improving the system that produced them.

Repeated classes of mistakes should result in stronger project rules, clearer documentation, or improved verification workflows.

## Prefer simple, readable code

Write the simplest code that correctly solves the problem.

- Readable and explicit beats clever and compact.
- A future reader - or the same person at 3am - should understand the code without reverse-engineering it.
- If a solution surprised you when you wrote it, it will surprise the next reader too.
- Three clear lines beat one clever expression.
- Avoid unnecessary abstraction, indirection, and generality.

AI tools tend toward impressive-looking solutions. Push back on complexity that is not earned by the problem.

Prefer consistency with the existing codebase over introducing theoretically cleaner but unfamiliar patterns.

## Track skills you personally develop in SKILLS_USED.md

AI tools can mask your own skill development if you are not deliberate about it.

Maintain a private `SKILLS_USED.md` file alongside the project. Add concise dated entries for:
- skills you actively built
- things you understood, debugged, designed, or decided yourself
- investigations and debugging work you drove
- tests and validation you personally performed
- decisions you made and why they mattered
- outcomes that could later become resume bullets

A task where the AI generated code and you approved it is not the same as a skill you genuinely hold. Be honest about the distinction.

This record is useful for:
- resume and portfolio evidence
- performance reviews
- understanding what you can credibly explain and defend in an interview

Do not commit or expose this file if it is intended as private.

## Instruction precedence

When instructions conflict, use this priority order:

1. Explicit user request in the current session
2. Security and safety constraints
3. Architecture and design documents
4. Project rules (`CLAUDE.md`)
5. Inline code comments and established local conventions
6. TODO items and journals
7. Historical decisions recorded in memory files

If conflicts remain unresolved:
- stop
- explain the conflict
- ask for clarification

Do not silently guess which instruction should win.

## Understand before modifying

Before changing code:
- identify the relevant subsystem
- read surrounding code
- identify invariants and conventions
- check whether similar patterns already exist elsewhere in the project
- understand why the current implementation exists

Do not immediately rewrite unfamiliar code.

Matching established project patterns is usually more important than introducing a theoretically cleaner abstraction.

Code that appears awkward may reflect:
- operational constraints
- compatibility requirements
- historical bugs
- performance characteristics
- external interfaces

Understand the reason before changing it.

## Prefer extending existing systems over introducing parallel ones

Before creating new abstractions, helpers, wrappers, services, or utilities:
- check whether equivalent functionality already exists
- extend existing systems where reasonable
- avoid creating duplicate patterns

AI tools frequently introduce redundant abstractions because local generation optimises for immediate completion rather than long-term maintainability.

Prefer consistency and reuse over novelty.

## Stop and ask when

Pause and request clarification if:
- requirements conflict
- the change may cause data loss
- behaviour is ambiguous
- security implications are unclear
- architectural intent cannot be inferred confidently
- multiple reasonable implementations exist with materially different tradeoffs

Do not continue by guessing when uncertainty materially affects correctness, safety, or maintainability.

## Optimise for maintainability over speed

AI should optimise for:
- maintainability
- correctness
- clarity

over speed of completion.

A slower correct change is preferable to a fast unstable one.

Code survives longer than prompts. Optimise for the future maintainer, not immediate completion.

# Recommended AI behaviour rules

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
- validation phrases
- pretending confidence where uncertainty exists

A thirty-second argument before implementing is better than chasing a bad change afterward.

If uncertain:
- state the uncertainty
- explain what information is missing
- suggest ways to verify

Do not simulate certainty to maintain conversational flow.

## Working with code

Preserve intentional diagnostics and documentation.

- Keep existing comments, debug output, and logging unless removal is explicitly requested.
- Improve comments and logging when useful, but explain what changed and why.
- If a comment, log line, or debug statement should be removed, say so and let the author decide.
- Avoid speculative refactors unrelated to the task.
- Prefer minimal, reviewable diffs.
- Write the simplest code that solves the problem.
- Avoid clever solutions when a straightforward one exists.
- When generating code, avoid reproducing verbatim patterns from known licensed sources.
- In commercial contexts, flag when a generated implementation closely resembles a specific known library or project.

Do not silently fix unrelated issues encountered during a task.

Record them separately if relevant, but keep task scope controlled unless expansion is explicitly approved.

Before making architectural changes:
- explain the reasoning
- explain tradeoffs
- identify risks
- confirm assumptions against existing design docs

When modifying existing code:
- preserve surrounding style and conventions unless intentionally standardising them
- avoid introducing unrelated formatting churn
- avoid renaming symbols without a clear reason

Consistency reduces maintenance cost.

## Verify external APIs and libraries

Do not assume:
- APIs exist
- methods exist
- configuration options are valid
- package names are correct
- examples found in memory are current

Verify against:
- official documentation
- existing project usage
- installed package versions
- actual runtime behaviour

Plausible-looking code is not evidence of correctness.

AI-generated examples are often syntactically plausible but operationally wrong.

## Generated files

If any files are generated artefacts - from templates, build pipelines, or code generators - document this prominently.

- Do not edit generated files directly.
- Fixes belong in the template source, not the generated output.
- The AI will edit whatever file it can find unless explicitly told otherwise.

Document:
- which files are generated
- what produces them
- how regeneration occurs

Record this in `CLAUDE.md` or equivalent project documentation.

## Sensitive data in AI sessions

AI tools are third-party services. Anything pasted into a session may be:
- logged
- retained
- used for training

Before pasting any content into an AI session:
- replace real account names, hostnames, IPs, and usernames with placeholders
- never paste credential files, API keys, tokens, or secrets
- sanitise log output and API responses before using them as examples
- treat session contents as if they could be read by anyone

If a session needs to work with sensitive structures or outputs:
- describe the structure rather than pasting the content directly

Document sanitisation conventions for the project so the same placeholders are used consistently across:
- examples
- issues
- documentation
- test fixtures

## Verification and testing

After each meaningful change:
- run tests
- run linters and checks where available
- verify expected behaviour
- report failures clearly

AI tools will confidently cite:
- library methods
- function signatures
- config options

that do not exist.

Running the code is what catches this.

Static review alone is insufficient, because a hallucinated method name is syntactically indistinguishable from a real one.

Do not claim something works without verification.

If verification cannot be performed:
- say so explicitly
- explain what remains unverified
- explain how it should be verified later

Verification should be treated as part of implementation, not an optional follow-up task.

## Security review of AI-generated code

AI tools introduce security vulnerabilities.

Generated code is syntactically plausible but may contain:
- hardcoded credentials or secrets
- command injection via string concatenation
- missing input validation at system boundaries
- insecure defaults
- invented or malicious package suggestions

Review all AI-generated code for these issues before accepting it.

Tests passing is not a proxy for security.

Tests verify behaviour, not safety.

When AI suggests adding a new package or dependency:
- verify it exists
- verify it is actively maintained
- verify it has no known CVEs before adding it

### Ongoing reviews

A single review at generation time is not sufficient.

AI-contributed code accumulates, and issues missed initially may only surface in combination with later changes.

Review AI-contributed code regularly - at minimum:
- when a significant feature completes
- when dependencies are updated

Review for:
- security patterns listed above
- accidentally committed credentials or sensitive data
- unnecessary or unsafe dependencies added on AI suggestion

Record each review in the project journal:
- what was checked
- what was found
- what was fixed

## Scope of authorisation

Approving one action does not authorise the same action in a different context.

Confirm risky or irreversible operations explicitly each time:
- pushing to a remote
- dropping or overwriting data
- force operations
- modifying shared infrastructure

When suggesting a shell command for the user to run:
- explain what it does before they run it
- flag anything destructive or difficult to reverse

Unless standing permission is recorded in a durable configuration file that both the human and AI can read, do not assume prior approval carries forward.

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

Summarise:
- why decisions were made
- what alternatives were rejected
- what uncertainties remain
- what future work was intentionally deferred

Do not record every tiny edit.

A useful journal captures reasoning and operational context, not just actions taken.

### Preserve evidence behind operational decisions

When introducing operational constants, safety rules, retries, timeouts, workarounds, thresholds, or other non-obvious behaviour, record why the decision exists and what evidence supports it.

Future maintainers should be able to determine:
- what problem was observed
- what evidence was gathered
- what behaviour was tested
- why the chosen value or rule was selected
- what uncertainty or tradeoffs still remain

Guidelines:
- Record investigation evidence while the decision is being explored.
- Move stable rationale into durable design or operational documentation.
- Keep inline code comments concise, but make the deeper reasoning traceable.
- Do not leave magic values or unusual behaviour without recoverable context.

For example, if a timeout is increased because testing showed a device regularly completes after the default timeout, record:
- the original failing behaviour
- the observed timing range
- the successful test window
- environmental conditions that affected the result
- any remaining uncertainty or operational risk

Operational behaviour without preserved reasoning eventually becomes superstition.

## Session startup

At the start of each session:
1. Read the journal.
2. Check parked ideas and open questions.
3. Note current project state before asking or being asked what to work on.

Do not rely on the AI to remember previous sessions.

Assume a cold start every time and let the files provide continuity.

# Recommended project structure

```text
project/
├── CLAUDE.md
├── SKILLS_USED.md
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
│   ├── coding-standards.md
│   ├── ai-workflow.md
│   ├── ai-rules.md
│   ├── ai-security.md
│   └── project-memory.md
├── todo.md
└── src/
```

# Short operational prompt

Once the project is structured properly, prompts can stay extremely small:

```text
Read the project docs and journal.
Complete the highest priority TODO item.
Use TDD where practical.
Update journal.md if new lessons, decisions, or operational knowledge emerge.
```

Most failed AI-assisted development workflows are fundamentally documentation and process failures, not prompt failures.

The structure matters far more than clever prompts.
