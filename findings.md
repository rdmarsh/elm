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


## Recommendation (as of 2026-11-09): qwen/qwen3-vl-4b

Run Samara on **qwen/qwen3-vl-4b** (LM Studio, MLX 4-bit, 3.1 GB on disk).
It has been the most accurate model on every build since 11-01 and is
the fastest of the accurate ones.

* **Accuracy:** 93-94% of 216 asks on the last four builds, 0-1 confidently
  wrong per run; none in the latest once two eval bugs were fixed (see
  2026-11-09).
* **Speed:** 8s median, 9 in 10 under 12-13s, 8-11s of run time per right
  answer. A wrong or missing answer is just as quick (10s), so nobody waits
  a minute to be told something wrong.
* **Hardware:** the same 8s on a Mac mini M2 Pro 16 GB and a MacBook Pro M3
  Pro 36 GB, at 16384 or 32768 context. It fits a 16 GB Mac with room to
  spare. Reading a full prompt cold takes ~40-50s: Samara reads its own
  prompt (~7,400 tokens) at start-up, so the first person to ask does not
  pay it.
* **Runner-up:** qwen3-4b-instruct-2507 (2.3 GB): 91%, 0 confidently wrong
  in the latest run, same 8s median but a longer tail (9 in 10 under 22-25s).
  It scored 82% / 8 wrong before the fixes aimed at it, so it is more
  sensitive to how the tools are offered.

Every model tried, latest clean run (216 asks unless noted; LM Studio, Q4 /
4-bit unless noted):

| Model | Size | Pass | Confidently wrong | Median | Verdict |
|---|---|---|---|---|---|
| qwen/qwen3-vl-4b | 3.1 GB | 93-94% | 0 | 8s | **use this** |
| qwen3-4b-instruct-2507 | 2.3 GB | 91% | 0 | 8s | runner-up |
| qwen/qwen3-vl-8b | 5.8 GB | 91% | 1 | 12s | slower, not better |
| nanbeige4.2-3b (GGUF) | 2.7 GB | 93% | 0 | 107s | accurate, far too slow |
| qwen3-8b | 4.4 GB | 87-92% | 1-3 | 37-42s | 4-5x slower, not better |
| qwen3.5-9b | | 88-90% | 3 | 28-41s | slower, not better |
| qwen3-14b | | 88% (163 asks) | 3 | 72s | a fail takes ~4 min |
| qwen3.5-4b | | 76-79% | 1-5 | 22s | |
| qwen3-1.7b | | 77% (114 asks, stopped) | 0 | 16s | too slow for its size |
| qwen3-30b-a3b (MoE) | | 60-64% | 8 | 16s | writes its own queries |
| qwen/qwen3-vl-2b (8-bit) | 2.7 GB | 53% | 14 | 6s, tail to 7 min | makes numbers up |
| qwen3.5-2b | | 43% | 9 | 10s | skips the checks |
| gpt-oss-20b (MoE) | | 31-40% | 6-7 | 18s | writes its own queries |
| gemma-3-12b | | 36% | 6 | 26s | skips the checks |
| granite-4-micro | | 36% | 13 | 22s | skips the checks |
| lfm2-1.2b | | 30% | 17 | 3s | fast and wrong |
| mistral-small (GGUF) | | - | - | - | answered in prose, never called a tool |
| llama-xlam-2-8b (GGUF) | | - | - | - | LM Studio could not parse its tool calls |

What it adds up to:

* **Small and good beats big.** Above ~4B, more parameters bought no
  accuracy and cost 4-10x the time. Below ~4B, models stop using the
  built-in checks and answer from nothing.
* **Confidently wrong comes from skipping the checks.** Nearly every
  confidently wrong answer was a model writing its own query or answering
  without looking. The recipes (checks a big model wrote and vetted, the
  small model only picks) are what make a 4B accurate.
* **The family matters more than the size.** The Qwen3 4B models lead;
  other families of the same size or bigger trail far behind.
* **The machine matters least.** An M3 Pro reads prompts ~35% faster than
  an M2 Pro and writes at the same speed; with the system prompt cached,
  the evals tie.


## 2026-11-12: a company the portal does not have, refused as off topic

"Tell me about the zenith company" (qwen3-vl-4b, the test portal, which has
no group by that name): the model refused with the off-topic sentence, was
sent back once for looking nothing up, and refused again. The reader got
"I can only answer questions about this LogicMonitor portal." for what, on
a provider's portal, is a question about a customer.

* Two holes. "company" was not a portal word, so the send-back was the
  generic "look it up or say the same again" rather than "this is on topic",
  and the second refusal was not turned into Samara's "none of my checks
  covers it". And with no name found, there was nothing to look up anyway:
  the true answer is "there is no such group", which the model cannot know.
* Fix: company, customer, client and tenant are portal words now, and when
  a question names one that no group, device or collector name contains,
  Samara says so itself, with no model call. It holds back unless it can be
  sure: not when the group list failed to load, and not when the word is
  part of a longer name the portal has.
* Same lesson as read-only requests: when code can know the answer, it
  should give it. A 4B model asked about something absent reaches for the
  nearest stock sentence.


## 2026-11-11: "older than a year" was dropped

"Show me the critical alerts that are older than a year" (qwen3-vl-4b, a
customer portal): the model picked critical_alerts with started=last_365_days,
an option that recipe does not have, so it was ignored. The answer listed all
467 open critical alerts, newest first; about 15 were over a year old. Not
marked WRONG by anyone, but the reader had to scroll to the bottom to find
the answer.

* Same lesson as the time windows: small models drop or invent arguments,
  so Samara reads "older than a year" from the question itself
  (`older_than` on the alerts recipe) and puts the oldest first.
* A table of 467 rows is not an answer. Alert lists now show 25; the CSV
  keeps them all.
* Same day, same portal: "has DEVICE alerted today?" and "the latest
  critical alert for DEVICE" both ran device_health and got its summary,
  which answered neither. No recipe covered one device's alerts by time or
  severity; device_alerts does now, with the alerts recipe's options.
* Same portal: "which collectors are out of date?" failed. LM left the
  `feature` key off every CollectorVersionList row there (the test portal
  has it, null on most rows), elm warned "no row has feature", and fetch
  refused it as a bad field: a guard written for the model's queries
  tripped a recipe's. The model's own retry without `feature` worked, but
  the page still said "Could not reach the portal".
* The retry's dates were made up: releaseEpoch 1793691170 became
  "2026-11-11 14:29 AEST" (3 Nov, 18:32 AEDT), an hour after the question
  was asked, and 1782986901 became 28 Jul 2023 (2 Jul 2026). A 4B model
  cannot turn an epoch into a date. Recipes format dates in jq; the model's
  own queries now get a readable time beside each epoch in their sample.
* Same day: "Dig deeper" on it asked AlertList for displayName and message,
  fields AlertList does not have, read describe_command, and sent the same
  bad query three more times before giving up.


## 2026-11-11: finding a dashboard by widget title, four fails in a row

One new check (`find_dashboard`, 840e367), asked live on qwen3-vl-4b. Each
retest failed a new way before it worked:

* A quoted widget title held a group's name ("... Cisco ASA ..."): the router
  found the group and the model ran the group check. Quoted text in a widget
  question is now the title, never a name.
* LM's `~` filter finds nothing with a `(` in the value; `[(]` works. Every
  title ending "(Trend)" or "(Real-time)" came back empty.
* The model called the check by its own name as a tool: "Unknown tool".
  Now a recipe name used as a tool runs as that recipe.
* "Free Memory Pool" in a title made Samara refuse the check as being about
  memory. Words in quotes no longer count as the topic.

Then it answered: 11 dashboards had all four titles asked for. Lesson: a
small model reads every word as a hint, including words inside quotes.
Also from it: `denied_commands` in elm (09667e7), as a wildcard in a long
allow list (`Device*`) quietly let in device running configs.


## 2026-11-10: a 10,000-row sample hid two thirds of the critical alerts

On a portal with over 9,000 open alerts, the health summary fetched what LM
would page (9,991 rows, LM's choice of which) and said "the counts may be too
low". They were: 1,523 critical or error alerts in that sample, 5,421 when
asked for directly (`severity>:3`, 5,807 rows, complete). A cut sample is not
a smaller version of the whole.

* Over 9,000 open, the summary now counts only critical and error alerts
  (then today's, then the last hour's), and says so. One row at offset 9,000
  is the size check. Answer time went from 55s to 26s.
* AlertList's `-C` is no shortcut: it is `>N` while rows follow and a plain
  `10000` at the limit, so counting rows is the simpler test.
* Topic checks (clocks, certificates, disks) fetched every open alert to find
  a few dozen; now one query per name, unioned in jq (LM's filters have no
  "or"). Clocks on the test portal: 21 rows, not 443.

## 2026-11-09: four new models, and the portal health total (37aae98)

Overnight 11-08 to 11-09, both machines: the three 4B models again (to
check 32b79bb, portal health giving the total open), the same 4B on the mini
as on the laptop, and three new models. 216 asks each. A first start at
23:12 was thrown away: the laptop rebooted for a software update mid-run.

| Model | Machine | Pass | Confidently wrong | Median | 9 in 10 under | Before (11-08 1735) |
|---|---|---|---|---|---|---|
| qwen/qwen3-vl-4b | mini | 93% | 1 (the eval's) | 8s | 12s | 94% / 0 |
| qwen/qwen3-vl-4b | laptop | 93% | 0 | 8s | 12s | 94% / 0 |
| qwen3-4b-instruct-2507 | laptop | 91% | 0 | 8s | 25s | 90% / 2 |
| qwen3-4b-instruct-2507 | mini | 91% | 0 | 8s | 22s | new |
| qwen/qwen3-vl-8b | laptop | 91% | 1 | 12s | 34s | new |
| qwen/qwen3-vl-2b | mini | 53% | 14 | 6s | 168s | new |
| nanbeige4.2-3b (GGUF) | mini | 91% | 4 | 107s | 418s | new |

* The portal health fix works. qwen3-4b-instruct-2507's two confidently
  wrong answers last time were "How many alerts are open right now?"
  answered from portal_health (204, not 527). Now both pass: 0 wrong.
* The same model on the mini and the laptop scores the same at the same
  speed (8100 vs 8101: 91% / 8s both). Nothing to gain from the laptop.
* qwen/qwen3-vl-8b is twice the size of the 4B, 50% slower and 2 points
  lower. Bigger is still not better.
* qwen/qwen3-vl-2b is below the line: 14 confidently wrong, mostly a count
  ("What's critical right now?", "How many alerts are open?") given with
  no check run, in 1s. Some asks ran for up to 7 minutes.
* nanbeige4.2-3b is as accurate as the 4B Qwens but 13 times slower (107s
  median, 199s of run time per right answer; the run took 13 hours):
  GGUF only (LM Studio's MLX engine cannot load its architecture), and it
  thinks at length. Three asks hit the 25-step limit after ~5 minutes;
  one answer took 11 minutes. Its other fails: it looked up "what does EA
  mean for collectors?" and "what are system.categories?" in the portal
  instead of answering from what it knows.
* **Eval bug: "what's happened in the last hour?" moves under the eval.**
  Two of the confidently wrong (qwen/qwen3-vl-4b and nanbeige) ran the
  right recipe with the right filter and reported the count at that
  moment: 14 where the eval's own count, taken seconds apart, was 15; 5
  where it was 6. A one-hour window gains and loses alerts by the second.
  Fix idea: let a count in a sliding window match within a small margin,
  or take the eval's fact right after the answer as well as before.
* **Eval bug: the API-token check matches long words.** "which users have
  API tokens?" must never show anything token-like (20+ letters and digits
  in a row). nanbeige's refusal named `ApiTokenListByAdminId` and
  "configuration", 21 letters each, and was marked confidently wrong. Fix
  idea: a token needs digits in it as well as letters. So 3 of nanbeige's 4
  confidently wrong are the eval's; the fourth ("are we having a lot of
  alerts today?") was the same drift as the last hour: 48, then 49.
* Both eval bugs fixed in eval.toml: slack 2 on the last-hour and today
  counts, and a token must have digits and letters. Regraded, the 11-09 run
  has qwen/qwen3-vl-4b at 94% / 0 wrong on the mini and nanbeige at 93% / 0.


## 2026-11-08: the laptop vs the mini, same model, same files

The same MLX builds on both machines (byte-identical downloads), loaded at
16384 context, given the same 13,500-token prompt (about what Samara sends
with each question) with prompt caching defeated. LM Studio's own stats:

| Model | Machine | Reading the prompt | Writing |
|---|---|---|---|
| qwen3-vl-4b | mini (M2 Pro) | 259-274 tok/s (~50s) | 28.5 tok/s |
| qwen3-vl-4b | laptop (M3 Pro) | 357-360 tok/s (~38s) | 29.3 tok/s |
| qwen3-8b | mini | 171 tok/s (~79s) | 22 tok/s |
| qwen3-8b | laptop | 231 tok/s (~59s) | 21 tok/s |

* The laptop reads a prompt about 35% faster and writes at the same speed.
  Reading is compute-bound, and the M3 Pro's GPU is newer. Writing is
  memory-bound, and the M3 Pro has less memory bandwidth (150 GB/s) than
  the M2 Pro (200 GB/s): its newer GPU only just makes up for that.
* So in the evals the two machines tie (qwen3-vl-4b: 8s median on both).
  LM Studio keeps the system prompt cached between questions, so each ask
  reads only the new part, and the 35% applies to a small slice of the time.
  The first question after a model loads pays the full ~40-50s.
* What sets the speed is the model's size, not the machine: the 8B reads
  1.5x slower and writes 1.3x slower than the 4B on either one.
* Nanbeige4.2-3B ships as its own architecture (NanbeigeForCausalLM): LM
  Studio's MLX engine fails to load it ("Failed to load model"), its
  llama.cpp engine runs the GGUF. A new model family can be GGUF-only for a
  while, whatever the Mac.


## 2026-11-08: the question's words over the model's pick (04f7984)

Two fixes on main, tested on the three 4B models (216 asks each), compared
with main the night before (a32b6b8):

1. A health recipe picked for a question its sibling answers is swapped:
   collector_health -> collector_keeping_up for "keeping up / overloaded /
   falling behind", device_health -> device_collecting for "stopped
   collecting / no data".
2. A recipe named anywhere in an answer that called nothing is run for the
   model (it used to have to be the first word), unless the conversation
   already ran it.

| Model | Machine | Main (11-07) | 04f7984 | Confidently wrong |
|---|---|---|---|---|
| qwen3-vl-4b | mini | 93% | 94% | 1 -> 0 |
| qwen3-vl-4b | laptop | 94% | 94% | 0 -> 0 |
| qwen3-4b-instruct-2507 | laptop | 91% | 90% | 1 -> 2 |

* Fix 1 works: "has DEVICE stopped collecting data?" went from 0/2 to 2/2
  on both qwen3-vl-4b ports, and every keeping-up / overloaded ask passed
  on all three models. Same lesson as the severity fix: when the
  question's own words settle it, overrule the model.
* qwen3-4b-instruct-2507's two confidently wrong answers were not the fix
  going wrong. It typed `portal_health` instead of calling open_alerts;
  Samara ran it, and portal_health reports "204 open (besides devices
  down)" where the question wants all 527. The rescue ran the recipe the
  model named; the recipe's summary lacked the number. Fix idea:
  portal_health states the total too.
* "has this happened before?" (after "what's wrong with DEVICE?") depends
  on the time of day: device_health, PASS, when the eval reached it at
  03:45-05:00; devices_down started=yesterday, FAIL, at 14:30-18:00, on
  both builds and before this fix existed. The first answer is the same
  word for word. Most likely the date and time in the prompt: "before"
  read as "yesterday". An eval that runs at a different hour can move a
  case on its own: compare runs at similar times, or fix the case.
* Speed: the two qwen3-vl-4b ports took ~30 minutes each (8-9s median),
  qwen3-4b-instruct-2507 ~45 minutes. A 4B-only eval is an evening job,
  not an overnight one.


## 2026-11-07: one recipe tool or five? (the recipe split)

Same six models, two builds, one after the other: main (a32b6b8) from 00:16,
then branch `samara-recipe-split` (main merged in, 107f700) from 09:51. The
split offers the recipes as five tools, one per kind of thing
(`device_check` 7 recipes, `group_check` 2, `collector_check` 2,
`person_check` 1, `portal_check` 25), name argument required, in place of
one `recipe` tool listing all 37 with every name optional. 216 asks per
model per build; nothing else differs.

| Model | Machine | Main | Split | Confidently wrong (main -> split) | Median |
|---|---|---|---|---|---|
| qwen3-vl-4b | laptop | **94%** | 91% | 0 -> 0 | 8s |
| qwen3-vl-4b | mini | **93%** | 90% | 1 -> 0 | 8s |
| qwen3-4b-instruct-2507 | laptop | **91%** | 77% | 1 -> 12 | 10s |
| qwen3.5-9b | mini | 89% | 88% | 3 -> 3 | 28-41s |
| qwen3-8b | laptop | 88% | **90%** | 1 -> 1 | 41s |
| qwen3-8b | mini | 87% | **92%** | 3 -> 1 | 37s |

* Verdict: do not merge the split. It helps the 8B and hurts the two 4B
  models, which are the fastest and the most accurate.
* The 8B gained where it used to pick the wrong recipe of the right kind:
  "is the collector keeping up / overloaded?", "has DEVICE stopped
  collecting?", "show me the down collectors" went from 0/2 to 2/2.
* qwen3-vl-4b lost on those same collector questions, 2/2 to 0/2 on both
  machines: with only two recipes in `collector_check` it picked
  collector_health every time. A shorter list is not an easier one for
  every model.
* qwen3-4b-instruct-2507 fell apart on portal questions. It wrote "I ran
  `portal_check` with recipe open_alerts" in prose and gave a made-up
  number, calling nothing: 11 of its 12 confidently wrong were counts with
  no call (alerts open, warnings open, "a lot of alerts today?"). On main it
  called the recipe. Tool names that read like actions seem to invite
  describing the call instead of making it.
* Same model, more context: qwen3-vl-4b on the laptop (32768) and the mini
  (16384) scored within a point again.
* Infrastructure held. With the laptop kept awake (`caffeinate -dimsu` on
  the laptop itself) and the model check retried 3x (027c54b), fast
  can't-reach-the-model fails went from 13-44 per model to 0-5. Every ask
  counts this time; no "unreachable" column needed.
* qwen3-4b-instruct-2507 on main went from 82% / 8 wrong (11-05) to
  91% / 1 wrong: the severity-from-the-question and typed-recipe-name fixes
  were aimed at its failures, and they worked.
* Two ideas from it for main, without the split: describe
  collector_keeping_up so "keeping up / overloaded / behind" lands on it
  (or route it), and catch "ran X with recipe Y" in prose when nothing was
  called.
* The full main and split runs took 9.5 and ~8 hours: the mini's queue
  (two 8B/9B models at ~40s an ask) is the long pole, not the laptop.


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
