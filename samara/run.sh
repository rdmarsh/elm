#!/usr/bin/env bash
# Samara run: start the samara container, choosing the model and effort.
#
# Usage:
#   run.sh [options]                 # asks for anything not given
#   run.sh --model NAME --effort medium --yes
#
# Options:
#   --model, -m NAME     Claude model line (haiku, sonnet, opus: the newest of
#                        that line answers) or one exact model id. Run without
#                        it to see the lines by number, default in [brackets].
#                        A comma list is the Think harder ladder, one model per
#                        step: qwen3:8b,sonnet asks a local model, then Claude.
#   --url URL            OpenAI-compatible API for models that are not Claude,
#                        e.g. Ollama at http://host.docker.internal:11434/v1
#   --effort, -e LEVEL   low | medium | high | xhigh | max (default: high)
#   --profile, -p NAME   elm credential profile (default: ai)
#   --port NUM           port on this machine (default: 8080 for ai; for
#                        ai-NAME, 8200-8999 from a checksum of the name, the
#                        same on every machine, so a link stays good)
#   --build              build the image first, from the repo root; with
#                        PYTHON_VERSION=3.12 exported, on that Python (for a
#                        TLS-inspecting proxy whose CA Python 3.13 rejects)
#   --yes, -y            don't ask anything: use the model (and --url) chosen
#                        last time, else the defaults
#   --no-open            don't open the browser (it opens when run.sh is
#                        started from a terminal, -y or not)
#   --dry-run            print the docker command instead of running it
#   --set-key            store (or replace) the Claude API key in the macOS
#                        keychain, then exit
#   -h, --help           show this help
#
# Model and effort are the two dials that decide what a question costs. The
# cheapest line is the default, and "Try harder" on the page re-asks one
# question on the next line up; lower effort means less thinking per step. Names and prices: https://www.anthropic.com/pricing
# Judge them on answers, not price: a cheaper model that needs three attempts
# is not cheaper.
#
# At the prompt, models on this machine are offered too: those LM Studio
# (port 1234) or Ollama (11434) list, or the --url server has. Picking one
# sets --url. The choice is kept in ~/.config/samara/last, so the next
# run.sh --build -y starts the same model.
#
# Run at a terminal without --yes, it opens the page in your browser once the
# server answers; with --yes, or with no terminal, it only prints the address.
#
# Needs a credential profile with allowed_commands (see ai.example.ini), and a
# Claude API key unless every model is at --url. The key comes from
# ANTHROPIC_API_KEY, or from the macOS keychain item named below (run.sh
# --set-key stores it). run.sh checks the key with the Claude API before
# starting, so a bad one shows here, not on the page. SAMARA_MODEL,
# SAMARA_MODEL_URL and SAMARA_MODEL_KEY (for an API that wants a key) are
# passed on when exported; the options win. So is SAMARA_RELAX_X509_STRICT=1,
# for a proxy CA that Python 3.13 rejects (README: Behind a proxy).
# Readers' ratings of answers (and the answer, if they include it) are kept in
# $XDG_STATE_HOME/samara/ on this machine; SAMARA_LOG=0 turns that off
# (README: Real questions). The page says they go to you, by your full name;
# SAMARA_OWNER="NOC team" names someone else. SAMARA_CONTACT (an email
# address or a link) adds how to reach them to the page's guide.
#
# Examples:
#   run.sh                                   # prompts, then starts
#   run.sh -y                                # image defaults, no questions
#   run.sh -m sonnet -e medium -y            # dearer line, less thinking
#   run.sh --profile ai-preprod -y           # its own port (run.sh says which)
#   run.sh --profile ai-preprod --port 8081 -y
#   run.sh -m qwen3:8b,sonnet --url http://host.docker.internal:11434/v1 -y
#
# Requires: docker

set -euo pipefail

IMAGE=samara
# Offered by number at the prompt, cheapest first. Lines, not models: Samara
# answers with the newest model in the line, so a new release needs no edit
# here. An exact model id typed at the prompt stays on that model.
# Prices: https://www.anthropic.com/pricing
MODELS=(
    "haiku|cheapest, and the default"
    "sonnet|mid-tier: more careful on multi-step questions"
    "opus|most capable, and the dearest"
)
# The default the image would use, read from the code next to this script so the
# two cannot drift apart.
KEYCHAIN_ITEM=${SAMARA_KEYCHAIN_ITEM:-${ELM_ASK_KEYCHAIN_ITEM:-anthropic-api-key}}   # macOS keychain item holding the key
DEFAULT_MODEL=$(sed -n 's/^MODEL = elm_tools.setting("MODEL", "\([^"]*\)")/\1/p' \
    "$(dirname "${BASH_SOURCE[0]}")/agent.py" 2>/dev/null) || true
DEFAULT_MODEL=${DEFAULT_MODEL:-image default}
MODEL=${SAMARA_MODEL:-${ELM_ASK_MODEL:-}}
URL=${SAMARA_MODEL_URL:-}
EFFORT=
PROFILE=ai
PORT=
BUILD=0
ASK=1
DRY_RUN=0
SET_KEY=0
OPEN=1
CREDS_DIR="$HOME/.config/logicmonitor/credentials"
LAST="${XDG_CONFIG_HOME:-$HOME/.config}/samara/last"   # MODEL<tab>URL of the last start
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

while [[ $# -gt 0 ]]; do
    case $1 in
        --model|-m)   MODEL=$2; shift 2 ;;
        --url)        URL=$2; shift 2 ;;
        --effort|-e)  EFFORT=$2; shift 2 ;;
        --profile|-p) PROFILE=$2; shift 2 ;;
        --port)       PORT=$2; shift 2 ;;
        --build)      BUILD=1; shift ;;
        --yes|-y)     ASK=0; shift ;;
        --no-open)    OPEN=0; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --set-key)    SET_KEY=1; shift ;;
        -h|--help)    sed -n '2,/^$/p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
        *)            printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done

# The key can live in the macOS keychain instead of a file or your shell
# history. --set-key stores it there (-U replaces an old one); security prompts
# for it, so no command line or history ever holds it.
if [[ $SET_KEY -eq 1 ]]; then
    command -v security >/dev/null || {
        echo "--set-key needs the macOS keychain; elsewhere, export ANTHROPIC_API_KEY." >&2
        exit 1
    }
    echo "Paste the Claude API key (from console.anthropic.com) at each prompt:" >&2
    security add-generic-password -U -a "$USER" -s "$KEYCHAIN_ITEM" -w
    echo "Stored as '$KEYCHAIN_ITEM' in your keychain." >&2
    [[ -z "${ANTHROPIC_API_KEY:-}" ]] ||
        echo "ANTHROPIC_API_KEY is set in this shell and wins over the keychain: unset it." >&2
    exit 0
fi

# Only an ai profile, as qlm and Samara itself (elm_tools.AI_PROFILE): never an
# everyday token by mistake. allowed_commands is checked inside the container.
case $PROFILE in
    *.example) ;;
    ai|ai-*) ai_ok=1 ;;
esac
[[ -n "${ai_ok:-}" ]] || {
    echo "Profile '$PROFILE' is not an ai profile: Samara uses only one named ai or ai-NAME (ai-$PROFILE.ini)." >&2
    echo "Copy ai.example.ini there as ai-$PROFILE.ini and put a read-only API token in it." >&2
    exit 1
}

# One port per profile, worked out from its name: the same on every machine,
# so a doc of ?q= links works for everyone who runs Samara, and a portal
# keeps its port whatever order they are started in. cksum is POSIX: macOS
# and Linux agree. 8200 up: models.sh uses 808x-810x. Two names can share a
# port (a few in 800); the check before docker run names the clash.
if [[ -z "$PORT" ]]; then
    if [[ $PROFILE == ai ]]; then
        PORT=8080
    else
        PORT=$(( 8200 + $(printf %s "$PROFILE" | cksum | cut -d' ' -f1) % 800 ))
    fi
fi

[[ -f "$CREDS_DIR/$PROFILE.ini" || $DRY_RUN -eq 1 ]] || {
    echo "No profile '$PROFILE' in $CREDS_DIR." >&2
    echo "Copy ai.example.ini there as $PROFILE.ini and put a read-only API token in it." >&2
    exit 1
}

# Models a server on this machine lists: "id|url for the container" lines.
# run.sh runs on the host, where the container's host.docker.internal is
# localhost. Embedding models cannot answer, so they are left out.
local_models() {
    local url probe
    for url in ${URL:-http://host.docker.internal:1234/v1 http://host.docker.internal:11434/v1}; do
        probe=${url/host.docker.internal/localhost}
        curl -fsS --max-time 3 "$probe/models" 2>/dev/null | grep -o '"id" *: *"[^"]*"' |
            sed 's/.*"\([^"]*\)"$/\1/' | grep -vi embed | sed "s#\$#|$url#" || true
    done
}

# -y and no model given: the last one started, if any.
if [[ -z "$MODEL" && $ASK -eq 0 && -f "$LAST" ]]; then
    IFS=$'\t' read -r MODEL last_url <"$LAST" || true
    URL=${URL:-$last_url}
fi

# Ask only when there is a terminal to ask at, and only for what was not given.
if [[ $ASK -eq 1 && -t 0 ]]; then
    if [[ -z "$MODEL" ]]; then
        CHOICES=("${MODELS[@]}")
        while IFS= read -r line; do
            # A --url server is another machine's unless it is this one.
            u=${line#*|}; where="on this machine, at $u"
            [[ $u =~ ://(localhost|127\.|host\.docker\.internal) ]] || where="on ${u#*://}"
            [[ -n $line ]] && CHOICES+=("${line%%|*}|${where%%/v1}|$u")
        done < <(local_models)
        echo "Model:"
        for i in "${!CHOICES[@]}"; do
            desc=${CHOICES[i]#*|}
            printf '  %d) %-18s %s\n' "$((i + 1))" "${CHOICES[i]%%|*}" "${desc%%|*}"
        done
        echo "  (a comma list is the Think harder ladder, e.g. qwen3-8b-mlx,sonnet)"
        read -r -p "  number or a model name [$DEFAULT_MODEL]: " MODEL
        # A number picks from the list; anything else is taken as a model name.
        if [[ "$MODEL" =~ ^[0-9]+$ ]]; then
            (( MODEL >= 1 && MODEL <= ${#CHOICES[@]} )) || { echo "No model $MODEL in the list." >&2; exit 1; }
            pick=${CHOICES[MODEL - 1]}
            MODEL=${pick%%|*}
            # A local model brings its server's address.
            [[ $(tr -cd '|' <<<"$pick") == "||" ]] && URL=${URL:-${pick##*|}}
        fi
    fi
    [[ -n "$EFFORT" ]] || read -r -p "Effort, low|medium|high|xhigh|max [high]: " EFFORT
fi

# A local model named without --url, typed at the prompt or given with -m: the
# server on this machine that lists it (-m qwen3-8b-mlx -y said "need --url").
if [[ -z "$URL" && -n "$MODEL" ]]; then
    IFS=, read -r -a typed <<<"$MODEL"
    for m in "${typed[@]}"; do
        found=$(local_models | grep -m1 "^${m// /}|") || true
        [[ -n $found ]] && { URL=${found#*|}; break; }
    done
fi

if [[ -n "$EFFORT" && ! "$EFFORT" =~ ^(low|medium|high|xhigh|max)$ ]]; then
    echo "Effort must be low, medium, high, xhigh or max (got '$EFFORT')." >&2
    exit 1
fi

# The Claude key only matters if a step is a Claude model: a line, a claude- id,
# or the default (a line). A ladder of local models needs none.
NEEDS_CLAUDE=0
IFS=, read -r -a steps <<<"${MODEL:-$DEFAULT_MODEL}"
for m in "${steps[@]}"; do
    [[ $m =~ ^\ *(haiku|sonnet|opus|claude-.*|image\ default)\ *$ ]] && NEEDS_CLAUDE=1
done
if [[ $NEEDS_CLAUDE -eq 0 && -z "$URL" ]]; then
    echo "None of '$MODEL' is a Claude model, so they need --url: the OpenAI-compatible" >&2
    echo "API that serves them (Ollama: http://host.docker.internal:11434/v1)." >&2
    exit 1
fi

if [[ $NEEDS_CLAUDE -eq 1 ]]; then
    KEY_FROM=ANTHROPIC_API_KEY
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && command -v security >/dev/null; then
        ANTHROPIC_API_KEY=$(security find-generic-password -a "$USER" -s "$KEYCHAIN_ITEM" -w 2>/dev/null) || true
        export ANTHROPIC_API_KEY
        KEY_FROM="the keychain item '$KEYCHAIN_ITEM'"
    fi

    [[ -n "${ANTHROPIC_API_KEY:-}" ]] || {
        echo "ANTHROPIC_API_KEY is not set (get a key at console.anthropic.com), and" >&2
        echo "nothing is stored as '$KEYCHAIN_ITEM' in your keychain. Either export it," >&2
        echo "or store it once and run.sh will find it from now on:" >&2
        echo "    $0 --set-key" >&2
        exit 1
    }

    # Check the key now, so a bad one stops here instead of failing the first
    # question on the page. Listing models costs nothing. The key reaches curl on
    # stdin, not its command line, where ps would show it. Only a 401 stops the
    # start: anything else (no network, a proxy) may not be the key's fault.
    if [[ $DRY_RUN -eq 0 ]]; then
        status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H @- \
            -H 'anthropic-version: 2023-06-01' https://api.anthropic.com/v1/models \
            <<<"x-api-key: $ANTHROPIC_API_KEY") || true
        case ${status:-000} in
            200) ;;
            401)
                echo "The Claude API rejected the key from $KEY_FROM (revoked, or mistyped)." >&2
                if [[ $KEY_FROM == ANTHROPIC_API_KEY ]]; then
                    echo "It is set in this shell, which overrides the keychain: unset it, or export a working key." >&2
                else
                    echo "Replace it with a new key from console.anthropic.com:  $0 --set-key" >&2
                fi
                exit 1 ;;
            *) echo "Could not check the Claude API key (HTTP ${status:-000}); starting anyway." >&2 ;;
        esac
    fi
fi

if [[ $BUILD -eq 1 ]]; then
    build=$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null) || build=unknown
    pyver=()
    [[ -n "${PYTHON_VERSION:-}" ]] && pyver=(--build-arg "PYTHON_VERSION=$PYTHON_VERSION")
    ( set -x; docker build -f "$REPO_ROOT/samara/dockerfile" --build-arg "SAMARA_BUILD=$build" \
        ${pyver[@]+"${pyver[@]}"} -t "$IMAGE" -t elm-ask "$REPO_ROOT" )   # elm-ask: its old name, for MCP setups that use it
elif ! docker image inspect "$IMAGE" >/dev/null 2>&1 && docker image inspect elm-ask >/dev/null 2>&1; then
    IMAGE=elm-ask   # built before the rename: use it until the next --build
elif ! docker image inspect "$IMAGE" >/dev/null 2>&1 && [[ $DRY_RUN -eq 0 ]]; then
    echo "No '$IMAGE' image yet. Run with --build (or: docker build -f samara/dockerfile -t $IMAGE .)" >&2
    exit 1
fi

# A Samara already on this port: say which profile it serves, not Docker's
# "port is already allocated".
if [[ $DRY_RUN -eq 0 ]] && running=$(curl -fs --max-time 2 "http://127.0.0.1:$PORT/api/health" 2>/dev/null); then
    other=$(printf %s "$running" | grep -o '"profile": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
    other=${other:-another profile}
    if [[ ${other%.ini} == "$PROFILE" ]]; then
        echo "Samara for $PROFILE is already running: http://127.0.0.1:$PORT/" >&2
    else
        echo "Port $PORT is taken by Samara for ${other%.ini}. Start $PROFILE with --port NUM." >&2
    fi
    exit 1
fi

# Only the profile in use is mounted, as one file: the container has no reason
# to hold the rest of your credentials. elm needs nothing dropped either.
cmd=(docker run --rm -p "127.0.0.1:$PORT:8080" --user "$(id -u)"
     --cap-drop ALL --security-opt no-new-privileges
     -e "ELM_CONFIG=/creds/$PROFILE.ini"
     -v "$CREDS_DIR/$PROFILE.ini:/creds/$PROFILE.ini:ro")
[[ $NEEDS_CLAUDE -eq 1 ]] && cmd+=(-e ANTHROPIC_API_KEY)
[[ -n "$MODEL" ]] && cmd+=(-e "SAMARA_MODEL=$MODEL")
[[ -n "$EFFORT" ]] && cmd+=(-e "SAMARA_EFFORT=$EFFORT")
if [[ -n "$URL" ]]; then
    cmd+=(-e "SAMARA_MODEL_URL=$URL")
    [[ -n "${SAMARA_MODEL_KEY:-}" ]] && cmd+=(-e SAMARA_MODEL_KEY)
    # Docker Desktop and Colima name the host already; Linux Docker does not.
    [[ $(uname) == Linux ]] && cmd+=(--add-host host.docker.internal:host-gateway)
fi
# A proxy's CA that Python 3.13's strict checks reject (see README "Behind a
# proxy that inspects TLS"): passed on only when exported, off by default.
[[ -n "${SAMARA_RELAX_X509_STRICT:-}" ]] && cmd+=(-e SAMARA_RELAX_X509_STRICT)
# The question log, on unless SAMARA_LOG=0: the answers people rate and send
# (each decides on the page), on this machine, in $XDG_STATE_HOME/samara/questions.jsonl.
if ! [[ ${SAMARA_LOG:-1} =~ ^(0|false|no|off)$ ]]; then
    LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/samara"
    mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR"
    cmd+=(-v "$LOG_DIR:/state" -e SAMARA_LOG_DIR=/state)
    # Who the page says ratings go to: SAMARA_OWNER, else your full name (the
    # GECOS field: id -F on macOS, getent on Linux), else your login.
    owner=${SAMARA_OWNER:-$(id -F 2>/dev/null || getent passwd "$USER" 2>/dev/null | cut -d: -f5 | cut -d, -f1)}
    cmd+=(-e "SAMARA_OWNER=${owner:-$USER}")
fi
# How to reach whoever runs this Samara, shown at the end of the page's guide:
# an email address or a link (SAMARA_CONTACT=noc@example.com).
[[ -n "${SAMARA_CONTACT:-}" ]] && cmd+=(-e SAMARA_CONTACT)
# The host's timezone, so the question log's times match the page's. Readers'
# answers use their own browser's zone either way.
tz=${TZ:-$(readlink /etc/localtime 2>/dev/null | sed -n 's|.*/zoneinfo/||p')}
[[ -n "$tz" ]] && cmd+=(-e "TZ=$tz")
# Someone is at the terminal (not models.sh, whose output goes to a log): have
# the local model read the prompt now, so the first question is not the slow one.
[[ -t 1 ]] && cmd+=(-e SAMARA_WARM=1)
cmd+=("$IMAGE")

if [[ $DRY_RUN -eq 1 ]]; then
    printf '%q ' "${cmd[@]}"; echo
    exit 0
fi

# Kept for the next run.sh -y (only what was chosen, never a key).
if [[ -n "$MODEL" ]]; then
    mkdir -p "$(dirname "$LAST")" && printf '%s\t%s\n' "$MODEL" "$URL" >"$LAST" || true
fi

printf 'Samara: profile %s, model %s, effort %s%s\n' \
    "$PROFILE" "${MODEL:-$DEFAULT_MODEL}" "${EFFORT:-high}" "${URL:+, models not Claude at $URL}"
URL="http://127.0.0.1:$PORT/"
printf 'Open %s  (ctrl-c here to stop)\n\n' "$URL"

# Open the browser once the server answers: opened sooner, it shows a "can't
# connect" page. Only when someone is at a terminal (models.sh's runs log to a
# file, so its ports open nothing), unless --no-open. The waiting runs in the
# background, so it outlives the exec below.
if [[ $OPEN -eq 1 && -t 1 ]] && opener=$(command -v open || command -v xdg-open); then
    ( for _ in $(seq 60); do
          curl -fs -o /dev/null "$URL" && exec "$opener" "$URL"
          sleep 0.5
      done ) &
fi
exec "${cmd[@]}"
