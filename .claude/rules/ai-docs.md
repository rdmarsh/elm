---
paths:
  - elm-knowledge.md
  - elm-notes.yaml
  - _jnja/elm.py.j2
  - mkinfo.py
  - examples/**
---

# AI-facing docs: keep them small

Three files are written for AI assistants as much as for people, and cost
tokens every time they are read:

- `elm-knowledge.md` -- read in full before every question (samara
  sends it with each one). Rules that hold across commands only.
- `elm-notes.yaml` -- one command's entry is shown by `elm COMMAND --info`
  each time that command is looked up.
- `elm --ai` (in `_jnja/elm.py.j2`) -- read at the start of a session.

Bigger is not safer. A long file costs more per question, and it collects
contradictions and stale claims that nobody re-reads (a "verified live"
severity mapping here was backwards for months). Before adding:

1. One home per fact. About one command -> its `elm-notes.yaml` entry. Holds
   across commands -> `elm-knowledge.md`. A recipe or background ->
   `examples/`. Never the same fact in two of them.
2. Don't repeat the swagger. `--info` already lists every field with its
   documented description; add a note only where testing shows something
   different or missing.
3. Say how it was verified and when, in a few words. If it wasn't verified,
   say so, or leave it out.
4. Fix or delete what is wrong; don't add a correction next to it.
5. Stay within budget. `make testdocs` fails if `elm-knowledge.md` passes
   8,000 characters or any command's `--info` passes 16,000, and the build
   fails on a duplicate key in `elm-notes.yaml`. Trim before raising a budget
   (budgets are in `mkinfo.py`).
