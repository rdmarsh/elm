#!/usr/bin/env bash
# Start Samara on each model the eval compares (MODELS below), one port each, in the
# background, and check each one can read its profile and reach its model.
#
# Usage:
#   samara/models.sh [--start]      # build, start them all, check each
#   samara/models.sh --eval         # start them, then ask eval.py's questions of each
#   samara/models.sh --status       # which are running, and the page of links
#   samara/models.sh --stop         # stop them
#   ... --only 8083,8085            # just these ports, with any of the above
#
# --eval takes hours. Models on the same server go one at a time, so LM
# Studio is not holding two at once and the timings mean something; each
# server (the laptop, this Mac, Claude) runs its own queue, side by side.
#
# A Claude model (url "claude") is billed per question, so it runs only when
# --only names its port.
#
# The laptop's LM Studio is at SAMARA_LAPTOP_URL (default below). Eval results
# go to SAMARA_EVAL_DIR (default tmp/tests/, which git ignores):
# eval-DATE-TIME-PORT.txt (safe to paste) and eval-DATE-TIME-PORT.jsonl (every
# answer: holds portal data, keep it). TIME is when --eval started. Server logs
# go to ~/.cache/samara/run-PORT.log. tmp/samara.html links to what is running
# and shows each one's latest eval (asks so far, or the summary line): written
# on start, as each eval starts and finishes, and by --status; emptied by --stop.

set -euo pipefail
cd "$(dirname "$0")/.."

LAPTOP=${SAMARA_LAPTOP_URL:-http://192.168.1.52:1234/v1}
MINI=http://host.docker.internal:1234/v1   # the container's name for this Mac
LOGS=${XDG_CACHE_HOME:-$HOME/.cache}/samara
EVALS=${SAMARA_EVAL_DIR:-tmp/tests}
PAGE=tmp/samara.html
MODELS=(
    "8080 openai/gpt-oss-20b $LAPTOP"
    "8081 qwen/qwen3-30b-a3b-2507 $LAPTOP"
    "8082 qwen3-8b-mlx $MINI"
    "8083 qwen/qwen3-vl-4b $MINI"
    # the same two on the laptop, at twice the context the mini can give them
    "8084 qwen3-8b-mlx $LAPTOP"
    "8085 qwen3-vl-4b-instruct-mlx $LAPTOP"   # a copied model gets a local id
    "8086 qwen3.5-4b-mlx $MINI"
    "8087 qwen/qwen3.5-9b $MINI"
    "8090 haiku claude"
    "8091 sonnet claude"
)

action=--start only=
while (($#)); do
    case $1 in
        --start|--eval|--status|--stop) action=$1; shift ;;
        --only) only=,$2,; shift 2 ;;
        *) echo "usage: samara/models.sh [--start|--eval|--status|--stop] [--only PORT,PORT]" >&2; exit 2 ;;
    esac
done
chosen=()
for m in "${MODELS[@]}"; do
    read -r port _ url <<<"$m"
    if [[ -n $only ]]; then [[ $only == *",$port,"* ]] || continue
    elif [[ $url == claude ]]; then continue; fi
    chosen+=("$m")
done
((${#chosen[@]})) || { echo "no model on ${only//,/ }" >&2; exit 2; }
mkdir -p "$LOGS" "$EVALS" "$(dirname "$PAGE")"

health() { curl -fs --max-time 2 "http://127.0.0.1:$1/api/health"; }
where() { case $1 in "$LAPTOP") echo laptop ;; "$MINI") echo "this Mac" ;; *) echo "$1" ;; esac; }

# A port's latest eval: its summary line once done, else how many asks it has answered.
progress() {
    local f; f=$(ls -t "$EVALS"/eval-*-"$1".txt 2>/dev/null | head -n1)
    [[ -n $f ]] || return 0
    if grep -q ' asks: ' "$f"; then grep ' asks: ' "$f" | sed 's/\. Answers in .*//; s/^ *//'
    else
        local n; n=$(grep -cE '^[0-9][0-9]:[0-9][0-9]  ' "$f")
        echo "$n asks so far$([[ $n -gt 0 ]] && echo ", last at $(grep -E '^[0-9][0-9]:[0-9][0-9]  ' "$f" | tail -n1 | cut -c1-5)")"
    fi
}

# The page lists every Samara of MODELS that answers, whatever --only says.
page() {
    local rows="" m port model url h tmp
    for m in "${MODELS[@]}"; do
        read -r port model url <<<"$m"
        h=$(health "$port" | python3 -c 'import json, sys; h = json.load(sys.stdin); print(h.get("model_id"), h.get("build"))' 2>/dev/null) || continue
        rows+="<tr><td><a href=\"http://127.0.0.1:$port\">127.0.0.1:$port</a></td><td>${h% *}</td><td>$(where "$url")</td><td>${h##* }</td><td>$(progress "$port")</td></tr>"
    done
    [[ -n $rows ]] || rows="<tr><td colspan=5>Nothing running (checked $(date '+%H:%M %a %d %b')).</td></tr>"
    tmp=$(mktemp "$PAGE.XXXXXX")   # one per writer: the eval queues call page() side by side
    cat >"$tmp" <<EOF
<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width">
<title>Samara instances</title>
<style>
:root { color-scheme: light dark; font: 15px system-ui, sans-serif }
body { margin: 2em auto; max-width: 52em; padding: 0 1em }
table { border-collapse: collapse; width: 100% } td, th { padding: .4em .8em; text-align: left; border-bottom: 1px solid #8884 }
</style>
<h1>Samara instances</h1>
<table><tr><th>Instance</th><th>Model</th><th>Model server</th><th>Build</th><th>Latest eval</th></tr>$rows</table>
<p><small>Written by samara/models.sh at $(date '+%H:%M %a %d %b'); --status writes it again.</small></p>
EOF
    mv "$tmp" "$PAGE"   # whole or not at all
}

if [[ $action == --stop ]]; then
    for m in "${chosen[@]}"; do
        read -r port _ <<<"$m"
        ids=$(docker ps -q --filter "publish=$port")
        [[ -n $ids ]] && docker stop $ids >/dev/null && echo "$port: stopped"
    done
    page
    exit 0
fi

if [[ $action == --status ]]; then
    for m in "${chosen[@]}"; do
        read -r port model url <<<"$m"
        if h=$(health "$port"); then
            echo "http://127.0.0.1:$port  $model ($(where "$url")), build $(python3 -c 'import json, sys; print(json.load(sys.stdin).get("build"))' <<<"$h")"
        else
            echo "http://127.0.0.1:$port  $model: not running"
        fi
    done
    page
    echo "page: $PWD/$PAGE"
    exit 0
fi

# Every model must be one its server lists: a wrong id would fail every question.
for m in "${chosen[@]}"; do
    read -r port model url <<<"$m"
    [[ $url == claude ]] && continue
    here=${url/host.docker.internal/127.0.0.1}
    if ! curl -fs "$here/models" | grep -q "\"$model\""; then
        echo "$port: $model is not listed at $here/models (is it downloaded, and the server on?)" >&2
        exit 1
    fi
done

build=--build   # the first build makes the image; the others reuse it
for m in "${chosen[@]}"; do
    read -r port model url <<<"$m"
    # A Samara already on the port would answer the checks below for the new one.
    if health "$port" >/dev/null; then
        echo "$port: something is already answering; run samara/models.sh --stop first" >&2
        exit 1
    fi
    at=(--url "$url"); [[ $url == claude ]] && at=()
    nohup samara/run.sh $build -y -m "$model" "${at[@]}" --port "$port" >"$LOGS/run-$port.log" 2>&1 &
    for _ in $(seq 900); do health "$port" >/dev/null && break; sleep 1; done   # a build takes minutes
    health "$port" | python3 -c '
import json, sys
h = json.load(sys.stdin)
problems = [h[k] for k in ("profile_problem", "model_problem") if h.get(k)]
print(sys.argv[1] + ": " + ("; ".join(problems) or "%s, build %s" % (h.get("model_id"), h.get("build"))))
sys.exit(1 if problems else 0)' "$port" || { echo "$port: see $LOGS/run-$port.log" >&2; exit 1; }
    build=
done
page
echo "page: $PWD/$PAGE"

[[ $action == --eval ]] || exit 0
run=$(date +%F-%H%M)
evaluate() {   # the ports given, one after another
    for port in "$@"; do
        paid=; [[ " $claude " == *" $port "* ]] && paid=--claude
        echo "$port: eval, see $EVALS/eval-$run-$port.txt"
        : >"$EVALS/eval-$run-$port.txt"; page || true
        samara/eval.py --url "http://127.0.0.1:$port" --repeat 2 $paid --out "$EVALS/eval-$run-$port.jsonl" \
            >"$EVALS/eval-$run-$port.txt" 2>&1 || echo "$port: eval failed, see that file" >&2
        page || true
    done
}
claude=$(for m in "${chosen[@]}"; do read -r port _ url <<<"$m"; [[ $url == claude ]] && echo "$port"; done | xargs)
servers=$(for m in "${chosen[@]}"; do read -r _ _ url <<<"$m"; echo "$url"; done | sort -u)
queues=()
for server in $servers; do
    evaluate $(for m in "${chosen[@]}"; do read -r port _ url <<<"$m"; [[ $url == "$server" ]] && echo "$port"; done) &
    queues+=($!)
done
wait "${queues[@]}"   # not a bare wait: the run.sh servers above are jobs too, and never end
tail -n1 "$EVALS"/eval-"$run"-*.txt
