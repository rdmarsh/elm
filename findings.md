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


## 2026-11-06: severity from the question, overnight on two machines

Build 85dfb15: Samara reads "errors or worse", a named severity and the
time window from the question itself, and runs a recipe whose name the model
typed as text. Six ports, mini and laptop queues side by side.

| Model | Machine | Before (11-05) | Now, real asks | Confidently wrong | Unreachable |
|---|---|---|---|---|---|
| qwen3-vl-4b | mini | 87%, 4 wrong | 95% (155/164) | 0 | 44 |
| qwen3-8b | mini | 89%, 2 wrong | 85% (166/195) | 0 | 13 |
| qwen3.5-9b | mini | 90%, 4 wrong | 87% (155/179) | 2 | 29 |
| qwen3-8b | laptop | - | 89% (164/184) | 1 | 24 |
| qwen3-vl-4b, qwen3-4b-instruct-2507 | laptop | - | not run | - | all |

* The fix worked: "show me errors or worse" and "how many warnings are open?"
  were confidently wrong on every model before and pass on every model now.
  Confidently wrong went from 2-4 per model to 0-2, and neither of those
  is an alert count.
* Taking the argument out of the model's hands beats asking it better. The
  model still picks the wrong window or the wrong recipe; Samara now
  overrules it with what the question's own words say.
* Infrastructure is now the biggest source of fails. The laptop left the
  network at 02:57 and two of its three models never ran (caffeinate on the
  mini does not keep the laptop awake). The mini's LM Studio missed Samara's
  1.5s connect check now and then: 13-44 asks per model failed in 2s.
  "Unreachable" asks are left out of the percentages above.
* A device that shares its name with a collector went to the collector on
  every ask for the first 15 minutes, on the two ports that started at the
  same moment, then came right. The router's first name list most likely
  came back without devices and was kept 15 minutes (fixed in 6a1a8dc: kept
  60s when a list is missing). That is most of qwen3-8b's drop on the mini.
* One false fail: "How many alerts cleared yesterday?" ran the right query
  after Samara rerouted it, but the eval grades the recipe the model named,
  not the one that ran.


## 2026-11-05: duplicate devices (tools/elm-duplicate-devices.py)

Started from a real case: one device added by IP, again by FQDN, same
serial and MAC.

* Five checks (serial, MAC, sysname, address, short name), scored "x of y"
  over the checks both devices have a value for. The score is what makes it
  usable: the test portal's pair was 5 of 5; a 1 of 3 pair shared an
  address but not serial or sysname, so two machines.
* It found a second duplicate that serial and MAC missed (neither device
  had one): matched on address and name.
* A name alone never lists a pair: two customers can each have a web01.
* Values on more than a few devices ("To be filled by O.E.M.", Docker's
  default bridge address) are noise; drop them rather than list a JUNK set forever.
* Across portals an address is weak evidence (private IPs repeat across
  customers), so a pair across needs serial, MAC or sysname.
* Test trick: two profiles on the same portal. Every device with a serial,
  MAC or sysname must pair with itself: 72 expected, 72 found, plus the
  known pair both ways round = 74.
* LM stops offset paging at 10,000 rows with no error. Paging by id
  (`-S id -F id>LAST`) gets past it; checked with 100-row pages.
* LM UI link to a device: `resources-ID` alone does not open it;
  `resourceGroups-1,resources-ID` does, whatever its group.


## 2026-11-05: severity questions go wrong on every model

"show me errors or worse" was confidently wrong on all three models run so
far (qwen3-8b, qwen3-vl-4b, qwen3.5-9b), through the alerts recipe and
through the model's own query: one model passed only critical, another no
severity, a third added a "started today" window to "how many warnings are
open?". The recipe is right; the arguments the model picks are not. Fix to
try: read "X or worse" and the time window from the question in code
(recipes.from_question), as is already done for "cleared".


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
