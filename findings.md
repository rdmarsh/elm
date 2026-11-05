# Findings

What we tested, the numbers, and what they taught us. Raw material for blog
posts (docs/_drafts) and for handing the work on. Newest first. Placeholders
only: no real portal, device, group or person names.

Each entry: date, what was run, the result, what it means.


## How Samara is tested

* `samara/eval.py` asks a running Samara ~100 questions twice each and grades
  every answer against the live portal: PASS, FAIL (wrong or no answer, but
  it says so or it is obvious) or WRONG (confidently wrong - the worst case).
* The questions use placeholders (`{device}`, `{collector}`), filled per
  portal from a values file kept out of the repo.
* `samara/models.sh --eval --only PORTS` runs one Samara per model, queued per
  model server, overnight. Local models only, so a run costs time, not money.
* Each answer is labelled by where it came from: a built-in check (recipe),
  the model's own query, or not looked up at all. That label explains most of
  the scores.


## 2026-11-05: speed against accuracy

Every eval since 11-01, per model. "Per right answer" is the run's total time
divided by its passes, so time spent on fails counts against it.

| Model | Pass | Median | 90% under | Median fail | Per right answer |
|---|---|---|---|---|---|
| qwen3-vl-4b | 91-95% | 8s | 11-13s | 6-10s | 8-9s |
| qwen3-8b | 89-95% | 34-39s | 95-157s | 52-166s | 54-66s |
| qwen3.5-9b | 87% | 28s | 47s | 5s | 32s |
| qwen3.5-4b | 79% | 22s | 69s | 20s | 42s |
| qwen3-14b | 90% | 72s | 307s | 262s | 146s |
| qwen3-30b-a3b | 61% | 16s | 38s | 13s | 32s |
| gpt-oss-20b | 40% | 18s | 46s | 19s | 53s |
| gemma-3-12b | 36% | 26s | 54s | 27s | 82s |

* The smallest good model wins: the 4B is as accurate as the 8B and 4-7x
  faster per right answer.
* Bigger models fail slowly. The 8B's fails take 1.5-5x as long as its
  passes; a 14B fail takes about 4 minutes. Nobody waits a minute to be
  told something wrong.
* Bigger is not more accurate here. The 30B and 20B score worse because they
  write their own queries or answer without looking, instead of using the
  built-in checks.
* eval.py now prints the time line itself (6f5202c).


## 2026-11-05: what the fails are

qwen3-8b, 204 asks: 89% pass, 2 confidently wrong.

* Most fails are the right kind of check, wrong one: collector health asked
  "is it keeping up?", device health asked "is it in maintenance?".
* Follow-ups with no look-up: "add a percentage to that table", "has this
  happened before?".
* Out of reach by design: integrations, collector versions, jargon.


## Earlier (from the eval history)

* 2026-10-29/30: qwen3-8b with no recipes passed about 1 in 4 of 194
  questions. It read a 5-row sample as the whole result, looped on refused
  calls, and made things up when stuck. Recipes (checks a big model writes
  and vets, the small model only picks) took it to 70%, then 95%.
* 2026-11-01: context size barely matters (16k vs 32k: same scores).
* 2026-11-01: recipes are what is accurate; nearly every confidently wrong
  answer came from the model's own query.
