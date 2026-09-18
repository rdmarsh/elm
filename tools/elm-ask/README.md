# elm ask

A local web page where anyone can ask questions about a LogicMonitor portal in
plain English:

- "Show me all the Windows devices that have alerts"
- "Show me SNMP errors older than 1 week"
- "What devices have alerting disabled?"

Claude works out which elm queries answer the question, runs them, and replies
with a short answer, sortable tables (with CSV download), caveats, and a
"How I worked this out" section plus the exact queries it ran.

Each answer has a **Save as PDF** button: it prints that one answer -- question,
text, tables in full and the queries behind it -- through the browser's print
dialog, where every browser offers "Save as PDF". The tables also download as
CSV for spreadsheet work.

It runs in a Docker container on the user's own machine, so nobody needs elm,
Python or jq installed.

**Status: prototype.**

## How it keeps data safe

- **Read-only.** Every LogicMonitor call goes through elm, which only has GET
  commands. The model can pick a command, filter, fields and paging. It cannot
  pass global elm flags, so it can't reach `-f api`, `-f curl` or `-f wget`
  (those print the signed Authorization header).
- **Secrets removed.** Before the model, jq or the page see a row, elm-ask removes fields that can
  carry secrets (collector `bearerToken` and config blobs, API token keys) and masks
  credential-like property values that LogicMonitor has not already masked.
- **Its own restricted profile.** elm-ask uses the `ai` profile, not your default
  `config`, and refuses to answer until `ai.ini` exists and sets
  `allowed_commands`. You have to create it on purpose, so an everyday token with
  wide rights is never the one the assistant uses by accident. elm-ask only
  offers and runs the commands that profile allows, and the model cannot choose
  another profile or config file.
- **An allowlist limits commands, not data.** Several allowed commands carry
  people's names: `SDTList` has the `admin` who created the downtime, `AlertList`
  has `ackedBy`, `DeviceList` has `createdBy`. Asked for "a list of users",
  elm-ask correctly says it cannot produce one and points at the LogicMonitor
  UI, but it can still name whoever appears in those fields. If that matters,
  give the profile's token a LogicMonitor role that cannot see those areas; that
  decides what data exists at all, which no list of commands can.
- **Read-only token.** Give it an LM API token whose role is read-only. That is
  the guarantee that holds even if everything else is wrong.
- **Local only.** The commands below publish the port on `127.0.0.1`, so only
  the person at that machine can open the page.
- **What leaves the machine.** Questions and the query results the model reads
  are sent to the Claude API. Tables shown on screen are rendered locally, but
  counts, samples and summaries do go to the API. Check that this is acceptable
  under your organisation's data policy.

## What you need

1. Docker (e.g. Docker Desktop, or Colima on macOS).
2. A Claude API key (`ANTHROPIC_API_KEY`).
3. An `ai` profile: copy [`ai.example.ini`](../../ai.example.ini) to
   `~/.config/logicmonitor/credentials/ai.ini`, fill in an API token whose
   LogicMonitor role is read-only, and adjust `allowed_commands` if you need to.
   The page tells you if the profile is missing or has no `allowed_commands`.

## Build

From the repository root:

```shell
docker build -f tools/elm-ask/Dockerfile -t elm-ask .
```

The build renders elm from `_jnja/` and the committed swagger snapshots inside
the image. It does not use your local `venv/`, `_cmds/` or `_dist/`.

## Run

macOS / Linux:

```shell
docker run --rm -p 127.0.0.1:8080:8080 --user "$(id -u)" \
  -e ANTHROPIC_API_KEY \
  -v ~/.config/logicmonitor/credentials:/home/app/.config/logicmonitor/credentials:ro \
  elm-ask
```

Windows (PowerShell):

```powershell
docker run --rm -p 127.0.0.1:8080:8080 `
  -e ANTHROPIC_API_KEY `
  -v "$env:USERPROFILE\.config\logicmonitor\credentials:/home/app/.config/logicmonitor/credentials:ro" `
  elm-ask
```

`--user "$(id -u)"` runs the container as you, so it can read your profile
(elm keeps credentials at mode 0600). Without it the page says the profile was
not found.

Then open <http://localhost:8080>.

### Choosing the profile

This uses the `ai` profile (`ai.ini`). To use a different one:

- **Another profile in your credentials folder**, e.g.
  `~/.config/logicmonitor/credentials/ai-preprod.ini`: pass its name, without
  `.ini`, as `ELM_PROFILE`.

  ```shell
  docker run --rm -p 127.0.0.1:8080:8080 --user "$(id -u)" \
    -e ANTHROPIC_API_KEY -e ELM_PROFILE=ai-preprod \
    -v ~/.config/logicmonitor/credentials:/home/app/.config/logicmonitor/credentials:ro \
    elm-ask
  ```

- **A profile file somewhere else**: mount that one file, and pass its path
  *inside the container* as `ELM_CONFIG`.

  ```shell
  docker run --rm -p 127.0.0.1:8080:8080 --user "$(id -u)" \
    -e ANTHROPIC_API_KEY -e ELM_CONFIG=/creds/preprod.ini \
    -v ~/somewhere/preprod.ini:/creds/preprod.ini:ro \
    elm-ask
  ```

If both are set, `ELM_CONFIG` wins. Either way the profile must set
`allowed_commands`, unless you also add `-e ELM_ASK_ALLOW_UNRESTRICTED=1`. The
page footer shows which profile is in use and how many commands it allows.

One elm-ask talks to one portal. For several, run one container per profile on
different ports (e.g. `ai-prod` on 8080, `ai-preprod` on 8081).

## Settings

| Variable | Default | Purpose |
|---|---|---|
| `ANTHROPIC_API_KEY` | (required) | Claude API key |
| `ANTHROPIC_BASE_URL` | Anthropic API | Send Claude requests through a gateway instead |
| `ELM_PROFILE` | `ai` | Credential profile name, as `elm --profile`. Must set `allowed_commands` |
| `ELM_ASK_ALLOW_UNRESTRICTED` | | Set to `1` to allow a profile without `allowed_commands` |
| `ELM_CONFIG` | | Path to a specific `.ini` inside the container (overrides `ELM_PROFILE`) |
| `ELM_CACERT` | | CA bundle for networks that inspect TLS, as `elm --cacert` (mount the file too) |
| `ELM_ASK_MODEL` | `claude-opus-5` | Claude model |
| `ELM_ASK_EFFORT` | API default | `low`, `medium`, `high`, `xhigh` or `max`: lower is faster and cheaper |
| `ELM_ASK_MAX_STEPS` | `25` | Maximum model turns per question |

## Run without Docker (development)

With elm built locally (`_cmds/`, `engine.py` and `elm.py` present) and `jq` on `PATH`:

```shell
pip install -r requirements.txt -r tools/elm-ask/requirements.txt
ANTHROPIC_API_KEY=... python tools/elm-ask/app.py      # http://127.0.0.1:8080
```

## How it works

| File | Role |
|---|---|
| `app.py` | Serves the page and streams answers from `/api/ask` as newline-delimited JSON |
| `agent.py` | The Claude tool-use loop |
| `elm_tools.py` | The five tools: `find_commands`, `describe_command`, `run_elm`, `jq` and `show_table` |
| `system_prompt.md` | How to interpret questions and write answers |
| `../../elm-knowledge.md` | Sent with every question: rules that apply across commands |
| `elm COMMAND --info` | Per-command notes and fields (from `elm-notes.yaml` and the swagger), returned by `describe_command` only when a command is looked up |

Each query's rows are saved as a dataset (`$d1`, `$d2`, ...) for that
conversation. The model counts, groups and joins them with jq instead of
reading every row.

## Making answers better

Most wrong answers come from plain words that don't map directly onto an API
field. For example, alert names don't say "SNMP", and the OS property can
reflect the collector rather than the device. When the tool gets something
wrong, record the lesson rather than changing the code: in `elm-notes.yaml` if
it is about one command, or in `elm-knowledge.md` if it applies across commands.
Keep `elm-knowledge.md` short, because it is sent with every question.

## Limitations

- It is built to run on one person's machine for that person: no login, the
  port bound to localhost, the user's own Claude key and LogicMonitor token.
  Hosting it for other people needs more first: authentication, TLS, a shared
  key with spend limits, a record of who asked what, and agreement on where
  portal data may be sent.
- A single elm query returns at most 1000 rows. The model is told to page, but
  very large portals make questions slower and more expensive.
- Conversations are kept in memory and dropped after an hour idle or when the
  container stops.
- Answers can be wrong. The "Queries run" list is there so they can be checked.
