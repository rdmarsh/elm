#!/usr/bin/env bash
# Start Samara on each model the eval compares (MODELS below), one port each, in the
# background, and check each one can read its profile and reach its model.
#
# Usage:
#   samara/models.sh            # build, start them all, check each
#   samara/models.sh --eval     # then ask eval.py's questions of each in turn
#   samara/models.sh --stop     # stop them
#
# --eval takes hours. Models on the same server go one at a time, so LM
# Studio is not holding two at once and the timings mean something; each
# server (the laptop, this Mac) runs its own queue, side by side.
#
# The laptop's LM Studio is at SAMARA_LAPTOP_URL (default below). Logs and
# results go to ~/.cache/samara/: run-PORT.log, eval-DATE-PORT.txt (safe to
# paste) and eval-DATE-PORT.jsonl (every answer: holds portal data, keep it).

set -euo pipefail
cd "$(dirname "$0")/.."

LAPTOP=${SAMARA_LAPTOP_URL:-http://192.168.1.52:1234/v1}
LOGS=${XDG_CACHE_HOME:-$HOME/.cache}/samara
MODELS=(
    "8080 openai/gpt-oss-20b $LAPTOP"
    "8081 qwen/qwen3-30b-a3b-2507 $LAPTOP"
    "8082 qwen3-8b-mlx http://host.docker.internal:1234/v1"
    "8083 qwen/qwen3-vl-4b http://host.docker.internal:1234/v1"
    # the same two on the laptop, at twice the context the mini can give them
    "8084 qwen3-8b-mlx $LAPTOP"
    "8085 qwen/qwen3-vl-4b $LAPTOP"
)
mkdir -p "$LOGS"

health() { curl -fs "http://127.0.0.1:$1/api/health"; }

if [[ ${1:-} == --stop ]]; then
    for m in "${MODELS[@]}"; do
        read -r port _ <<<"$m"
        ids=$(docker ps -q --filter "publish=$port")
        [[ -n $ids ]] && docker stop $ids >/dev/null && echo "$port: stopped"
    done
    exit 0
fi

# Every model must be one its server lists: a wrong id would fail every question.
for m in "${MODELS[@]}"; do
    read -r port model url <<<"$m"
    here=${url/host.docker.internal/127.0.0.1}   # the container's name for this Mac
    if ! curl -fs "$here/models" | grep -q "\"$model\""; then
        echo "$port: $model is not listed at $here/models (is it downloaded, and the server on?)" >&2
        exit 1
    fi
done

build=--build   # the first build makes the image; the others reuse it
for m in "${MODELS[@]}"; do
    read -r port model url <<<"$m"
    # A Samara already on the port would answer the checks below for the new one.
    if health "$port" >/dev/null; then
        echo "$port: something is already answering; run samara/models.sh --stop first" >&2
        exit 1
    fi
    nohup samara/run.sh $build -y -m "$model" --url "$url" --port "$port" >"$LOGS/run-$port.log" 2>&1 &
    for _ in $(seq 900); do health "$port" >/dev/null && break; sleep 1; done   # a build takes minutes
    health "$port" | python3 -c '
import json, sys
h = json.load(sys.stdin)
problems = [h[k] for k in ("profile_problem", "model_problem") if h.get(k)]
print(sys.argv[1] + ": " + ("; ".join(problems) or "%s, build %s" % (h.get("model_id"), h.get("build"))))
sys.exit(1 if problems else 0)' "$port" || { echo "$port: see $LOGS/run-$port.log" >&2; exit 1; }
    build=
done

[[ ${1:-} == --eval ]] || exit 0
day=$(date +%F)
evaluate() {   # the ports given, one after another
    for port in "$@"; do
        echo "$port: eval, see $LOGS/eval-$day-$port.txt"
        samara/eval.py --url "http://127.0.0.1:$port" --repeat 2 --out "$LOGS/eval-$day-$port.jsonl" \
            >"$LOGS/eval-$day-$port.txt" 2>&1 || echo "$port: eval failed, see that file" >&2
    done
}
servers=$(for m in "${MODELS[@]}"; do read -r _ _ url <<<"$m"; echo "$url"; done | sort -u)
for server in $servers; do
    evaluate $(for m in "${MODELS[@]}"; do read -r port _ url <<<"$m"; [[ $url == "$server" ]] && echo "$port"; done) &
done
wait
tail -n1 "$LOGS"/eval-"$day"-*.txt
