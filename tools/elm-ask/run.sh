#!/usr/bin/env bash
# elm-ask run: start the elm-ask container, choosing the model and effort.
#
# Usage:
#   run.sh [options]                 # asks for anything not given
#   run.sh --model NAME --effort medium --yes
#
# Options:
#   --model, -m NAME     Claude model. Run without it to see the models offered
#                        by number, with the default in [brackets].
#   --effort, -e LEVEL   low | medium | high | xhigh | max (default: the API's)
#   --profile, -p NAME   elm credential profile (default: ai)
#   --port NUM           port on this machine (default: 8080)
#   --build              build the image first, from the repo root
#   --yes, -y            don't ask anything; use the defaults for what is unset
#   --dry-run            print the docker command instead of running it
#   -h, --help           show this help
#
# Model and effort are the two dials that decide what a question costs. The
# most capable model is the default and the dearest; a mid-tier one usually
# answers these questions for a fraction of it; lower effort means less
# thinking per step. Names and prices: https://www.anthropic.com/pricing
# Judge them on answers, not price: a cheaper model that needs three attempts
# is not cheaper.
#
# Run at a terminal without --yes, it opens the page in your browser once the
# server answers; with --yes, or with no terminal, it only prints the address.
#
# Needs a Claude API key and a credential profile with allowed_commands (see
# ai.example.ini). The key comes from ANTHROPIC_API_KEY, or from the macOS
# keychain item named below, which run.sh tells you how to store.
#
# Examples:
#   run.sh                                   # prompts, then starts
#   run.sh -y                                # image defaults, no questions
#   run.sh -m claude-sonnet-5 -e medium -y   # cheaper model, less thinking
#   run.sh --profile ai-preprod --port 8081 -y
#
# Requires: docker

set -euo pipefail

IMAGE=elm-ask
# Offered by number at the prompt, dearest first. Typing any other model name
# works too, so this list only needs touching when you want a newly released
# model offered by number. Prices: https://www.anthropic.com/pricing
MODELS=(
    "claude-opus-5|most capable, and the dearest"
    "claude-sonnet-5|mid-tier: more careful on multi-step questions"
    "claude-haiku-4-5|cheapest, and the default; takes no effort setting"
)
# The default the image would use, read from the code next to this script so the
# two cannot drift apart.
KEYCHAIN_ITEM=${ELM_ASK_KEYCHAIN_ITEM:-anthropic-api-key}   # macOS keychain item holding the key
DEFAULT_MODEL=$(sed -n 's/^MODEL = os.environ.get("ELM_ASK_MODEL", "\([^"]*\)")/\1/p' \
    "$(dirname "${BASH_SOURCE[0]}")/agent.py" 2>/dev/null) || true
DEFAULT_MODEL=${DEFAULT_MODEL:-image default}
MODEL=
EFFORT=
PROFILE=ai
PORT=8080
BUILD=0
ASK=1
DRY_RUN=0
CREDS_DIR="$HOME/.config/logicmonitor/credentials"
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

while [[ $# -gt 0 ]]; do
    case $1 in
        --model|-m)   MODEL=$2; shift 2 ;;
        --effort|-e)  EFFORT=$2; shift 2 ;;
        --profile|-p) PROFILE=$2; shift 2 ;;
        --port)       PORT=$2; shift 2 ;;
        --build)      BUILD=1; shift ;;
        --yes|-y)     ASK=0; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)    sed -n '2,/^$/p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
        *)            printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done

# The key can live in the macOS keychain instead of a file or your shell
# history; store it once with:
#   security add-generic-password -a "$USER" -s "$KEYCHAIN_ITEM" -w
# (no value on the command line: it prompts, and history keeps nothing).
if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && command -v security >/dev/null; then
    ANTHROPIC_API_KEY=$(security find-generic-password -a "$USER" -s "$KEYCHAIN_ITEM" -w 2>/dev/null) || true
    export ANTHROPIC_API_KEY
fi

[[ -n "${ANTHROPIC_API_KEY:-}" ]] || {
    echo "ANTHROPIC_API_KEY is not set (get a key at console.anthropic.com), and" >&2
    echo "nothing is stored as '$KEYCHAIN_ITEM' in your keychain. Either export it," >&2
    echo "or store it once and run.sh will find it from now on:" >&2
    echo "    security add-generic-password -a \"\$USER\" -s $KEYCHAIN_ITEM -w" >&2
    exit 1
}

[[ -f "$CREDS_DIR/$PROFILE.ini" || $DRY_RUN -eq 1 ]] || {
    echo "No profile '$PROFILE' in $CREDS_DIR." >&2
    echo "Copy ai.example.ini there as $PROFILE.ini and put a read-only API token in it." >&2
    exit 1
}

# Ask only when there is a terminal to ask at, and only for what was not given.
if [[ $ASK -eq 1 && -t 0 ]]; then
    if [[ -z "$MODEL" ]]; then
        echo "Model:"
        for i in "${!MODELS[@]}"; do
            printf '  %d) %-18s %s\n' "$((i + 1))" "${MODELS[i]%%|*}" "${MODELS[i]#*|}"
        done
        read -r -p "  number or a model name [$DEFAULT_MODEL]: " MODEL
        # A number picks from the list; anything else is taken as a model name.
        if [[ "$MODEL" =~ ^[0-9]+$ ]]; then
            (( MODEL >= 1 && MODEL <= ${#MODELS[@]} )) || { echo "No model $MODEL in the list." >&2; exit 1; }
            MODEL=${MODELS[MODEL - 1]%%|*}
        fi
    fi
    [[ -n "$EFFORT" ]] || read -r -p "Effort, low|medium|high|xhigh|max [none]: " EFFORT
fi

if [[ -n "$EFFORT" && ! "$EFFORT" =~ ^(low|medium|high|xhigh|max)$ ]]; then
    echo "Effort must be low, medium, high, xhigh or max (got '$EFFORT')." >&2
    exit 1
fi

if [[ $BUILD -eq 1 ]]; then
    ( set -x; docker build -f "$REPO_ROOT/tools/elm-ask/dockerfile" -t "$IMAGE" "$REPO_ROOT" )
elif ! docker image inspect "$IMAGE" >/dev/null 2>&1 && [[ $DRY_RUN -eq 0 ]]; then
    echo "No '$IMAGE' image yet. Run with --build (or: docker build -f tools/elm-ask/dockerfile -t $IMAGE .)" >&2
    exit 1
fi

# Only the profile in use is mounted, as one file: the container has no reason
# to hold the rest of your credentials. elm needs nothing dropped either.
cmd=(docker run --rm -p "127.0.0.1:$PORT:8080" --user "$(id -u)"
     --cap-drop ALL --security-opt no-new-privileges
     -e ANTHROPIC_API_KEY -e "ELM_CONFIG=/creds/$PROFILE.ini"
     -v "$CREDS_DIR/$PROFILE.ini:/creds/$PROFILE.ini:ro")
[[ -n "$MODEL" ]] && cmd+=(-e "ELM_ASK_MODEL=$MODEL")
[[ -n "$EFFORT" ]] && cmd+=(-e "ELM_ASK_EFFORT=$EFFORT")
cmd+=("$IMAGE")

if [[ $DRY_RUN -eq 1 ]]; then
    printf '%q ' "${cmd[@]}"; echo
    exit 0
fi

printf 'elm-ask: profile %s, model %s, effort %s\n' \
    "$PROFILE" "${MODEL:-$DEFAULT_MODEL}" "${EFFORT:-none}"
URL="http://127.0.0.1:$PORT/"
printf 'Open %s  (ctrl-c here to stop)\n\n' "$URL"

# Open the browser once the server answers: opened sooner, it shows a "can't
# connect" page. Only when someone is at a terminal and did not say --yes. The
# waiting runs in the background, so it outlives the exec below.
if [[ $ASK -eq 1 && -t 1 ]] && opener=$(command -v open || command -v xdg-open); then
    ( for _ in $(seq 60); do
          curl -fs -o /dev/null "$URL" && exec "$opener" "$URL"
          sleep 0.5
      done ) &
fi
exec "${cmd[@]}"
