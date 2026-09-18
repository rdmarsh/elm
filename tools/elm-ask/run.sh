#!/usr/bin/env bash
# elm-ask run: start the elm-ask container, choosing the model and effort.
#
# Usage:
#   run.sh [options]                 # asks for anything not given
#   run.sh --model NAME --effort medium --yes
#
# Options:
#   --model, -m NAME     Claude model (default: the image's own default)
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
# Needs ANTHROPIC_API_KEY in the environment, and a credential profile with
# allowed_commands (see ai.example.ini).
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

[[ -n "${ANTHROPIC_API_KEY:-}" ]] || {
    echo "ANTHROPIC_API_KEY is not set. Export it first (console.anthropic.com)." >&2
    exit 1
}

[[ -f "$CREDS_DIR/$PROFILE.ini" || $DRY_RUN -eq 1 ]] || {
    echo "No profile '$PROFILE' in $CREDS_DIR." >&2
    echo "Copy ai.example.ini there as $PROFILE.ini and put a read-only API token in it." >&2
    exit 1
}

# Ask only when there is a terminal to ask at, and only for what was not given.
if [[ $ASK -eq 1 && -t 0 ]]; then
    [[ -n "$MODEL" ]] || read -r -p "Model [image default]: " MODEL
    [[ -n "$EFFORT" ]] || read -r -p "Effort, low|medium|high|xhigh|max [API default]: " EFFORT
fi

if [[ -n "$EFFORT" && ! "$EFFORT" =~ ^(low|medium|high|xhigh|max)$ ]]; then
    echo "Effort must be low, medium, high, xhigh or max (got '$EFFORT')." >&2
    exit 1
fi

if [[ $BUILD -eq 1 ]]; then
    ( set -x; docker build -f "$REPO_ROOT/tools/elm-ask/Dockerfile" -t "$IMAGE" "$REPO_ROOT" )
elif ! docker image inspect "$IMAGE" >/dev/null 2>&1 && [[ $DRY_RUN -eq 0 ]]; then
    echo "No '$IMAGE' image yet. Run with --build (or: docker build -f tools/elm-ask/Dockerfile -t $IMAGE .)" >&2
    exit 1
fi

cmd=(docker run --rm -p "127.0.0.1:$PORT:8080" --user "$(id -u)"
     -e ANTHROPIC_API_KEY -e "ELM_PROFILE=$PROFILE"
     -v "$CREDS_DIR:/home/app/.config/logicmonitor/credentials:ro")
[[ -n "$MODEL" ]] && cmd+=(-e "ELM_ASK_MODEL=$MODEL")
[[ -n "$EFFORT" ]] && cmd+=(-e "ELM_ASK_EFFORT=$EFFORT")
cmd+=("$IMAGE")

if [[ $DRY_RUN -eq 1 ]]; then
    printf '%q ' "${cmd[@]}"; echo
    exit 0
fi

printf 'elm-ask: profile %s, model %s, effort %s\n' \
    "$PROFILE" "${MODEL:-image default}" "${EFFORT:-API default}"
printf 'Open http://localhost:%s  (ctrl-c here to stop)\n\n' "$PORT"
exec "${cmd[@]}"
