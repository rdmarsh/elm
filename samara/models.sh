#!/usr/bin/env bash
# Start Samara on each model the eval compares (MODELS below), one port each, in the
# background, and check each one can read its profile and reach its model.
#
# Usage:
#   samara/models.sh [--start]      # build, start them all, check each
#   samara/models.sh --eval         # start them, then ask eval.py's questions of each
#   samara/models.sh --quick        # --eval with one question, once: a minute, not hours
#   samara/models.sh --status       # which are running, and the page of links
#   samara/models.sh --stop         # stop them (Claude ones too)
#   ... --only 8083,8085            # just these ports, with any of the above
#
# --eval takes hours. Models on the same server go one at a time, so LM
# Studio is not holding two at once and the timings mean something; each
# server (the laptop, this Mac, Claude) runs its own queue, side by side.
#
# A port in NAMED starts only when --only names it: the Claude models are
# billed per question. Dropped after an eval: gpt-oss-20b (40% on 2026-11-01;
# the small Qwens 87-95%) and gemma-3-12b (36% on 2026-11-04, mostly by
# skipping the recipes).
#
# Before each eval, models.sh loads that model itself, alone on its server, at
# the server's context (16384 on this Mac, 32768 on the laptop), and loads it
# again if LM Studio drops or reloads it: a load on demand uses LM Studio's own
# default (8192 for gemma-3 and qwen3-14b, whatever the model's settings say),
# which Samara's prompt does not fit.
#
# The laptop's LM Studio is at SAMARA_LAPTOP_URL (default below). Eval results
# go to SAMARA_EVAL_DIR (default tmp/tests/, which git ignores):
# eval-DATE-TIME-PORT.txt (safe to paste) and eval-DATE-TIME-PORT.jsonl (every
# answer: holds portal data, keep it); --quick adds -quick to the name, and the
# page leaves those out. TIME is when --eval started. Server logs
# go to ~/.cache/samara/run-PORT.log. tmp/samara.html links to what is running
# and shows each one's latest eval (asks so far, or the summary line): written
# on start, every minute while --eval runs, and by --status; emptied by --stop.
# The browser reloads it every minute.

set -euo pipefail
# set -e alone stops without a word, which hid a bug for half an hour.
trap 'echo "models.sh: stopped at line $LINENO: $BASH_COMMAND (servers may still be up: --stop)" >&2' ERR
cd "$(dirname "$0")/.."

LAPTOP=${SAMARA_LAPTOP_URL:-http://192.168.1.52:1234/v1}
MINI=http://host.docker.internal:1234/v1   # the container's name for this Mac
CONTEXT_MINI=${SAMARA_MINI_CONTEXT:-16384}
CONTEXT_LAPTOP=${SAMARA_LAPTOP_CONTEXT:-32768}
LOGS=${XDG_CACHE_HOME:-$HOME/.cache}/samara
EVALS=${SAMARA_EVAL_DIR:-tmp/tests}
PAGE=tmp/samara.html
MODELS=(
    "8082 qwen3-8b-mlx $MINI"
    "8083 qwen/qwen3-vl-4b $MINI"
    # the same two on the laptop, at twice the context the mini can give them
    "8084 qwen3-8b-mlx $LAPTOP"
    "8085 qwen/qwen3-vl-4b $LAPTOP"
    "8086 qwen3.5-4b-mlx $MINI"
    "8087 qwen/qwen3.5-9b $MINI"
    "8088 qwen/qwen3-14b $MINI"
    "8090 haiku claude"
    "8091 sonnet claude"
    # copied from this Mac by the laptop's cron, so the laptop gives them its own ids
    "8092 qwen3-14b-mlx $LAPTOP"
    "8094 mistral-small-3.2-24b-instruct-2506 $LAPTOP"   # GGUF: slower than MLX
)
NAMED=,8090,8091,

action=--start only=
while (($#)); do
    case $1 in
        --start|--eval|--quick|--status|--stop) action=$1; shift ;;
        --only) only=,$2,; shift 2 ;;
        *) echo "usage: samara/models.sh [--start|--eval|--quick|--status|--stop] [--only PORT,PORT]" >&2; exit 2 ;;
    esac
done
chosen=()
for m in "${MODELS[@]}"; do
    read -r port _ url <<<"$m"
    if [[ -n $only ]]; then [[ $only == *",$port,"* ]] || continue
    elif [[ $NAMED == *",$port,"* && $action != --stop && $action != --status ]]; then continue; fi
    chosen+=("$m")
done
((${#chosen[@]})) || { echo "no model on ${only//,/ }" >&2; exit 2; }
mkdir -p "$LOGS" "$EVALS" "$(dirname "$PAGE")"

health() { curl -fs --max-time 2 "http://127.0.0.1:$1/api/health"; }
where() { case $1 in "$LAPTOP") echo laptop ;; "$MINI") echo "this Mac" ;; *) echo "$1" ;; esac; }

# MODEL URL: make MODEL the only model loaded on URL's LM Studio, at that server's
# context. Does nothing when it already is. Says so when it loads, and why.
load() {
    local context=$CONTEXT_MINI; [[ $2 == "$LAPTOP" ]] && context=$CONTEXT_LAPTOP
    python3 - "${2/host.docker.internal/127.0.0.1}" "$1" "$context" <<'EOF'
import json, sys, urllib.request
base, model, context = sys.argv[1].removesuffix("/v1") + "/api/v1/models", sys.argv[2], int(sys.argv[3])
def call(path="", body=None):
    req = urllib.request.Request(base + path, json.dumps(body).encode() if body else None,
                                 {"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.load(r)
loaded = [(m["key"], i["id"], i["config"]["context_length"])
          for m in call()["models"] for i in m.get("loaded_instances", [])]
if [(k, c) for k, _, c in loaded] == [(model, context)]:
    sys.exit(0)
for _, instance, _ in loaded:
    call("/unload", {"instance_id": instance})
call("/load", {"model": model, "context_length": context})
print(f"{model}: loaded at {context}" + (f" (was {', '.join(f'{k} at {c}' for k, _, c in loaded)})" if loaded else ""))
EOF
}

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
<meta http-equiv=refresh content=60>
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
    if ! curl -fs --max-time 5 "$here/models" | grep -q "\"$model\""; then
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
    pid=$!
    for _ in $(seq 900); do   # a build takes minutes; a run.sh that has died will not answer
        health "$port" >/dev/null && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if ! h=$(health "$port"); then echo "$port: did not start, see $LOGS/run-$port.log" >&2; exit 1; fi
    python3 -c '
import json, sys
h = json.load(sys.stdin)
problems = [h[k] for k in ("profile_problem", "model_problem") if h.get(k)]
print(sys.argv[1] + ": " + ("; ".join(problems) or "%s, build %s" % (h.get("model_id"), h.get("build"))))
sys.exit(1 if problems else 0)' "$port" <<<"$h" || { echo "$port: see $LOGS/run-$port.log" >&2; exit 1; }
    build=
done
page
echo "page: $PWD/$PAGE"

[[ $action == --eval || $action == --quick ]] || exit 0
run=$(date +%F-%H%M) q= asks=(--repeat 2)
if [[ $action == --quick ]]; then q=-quick asks=(--repeat 1 --only "is {device} okay?"); fi
evaluate() {   # the ports given, one after another
    for port in "$@"; do
        paid=; [[ " $claude " == *" $port "* ]] && paid=--claude
        echo "$port: eval, see $EVALS/eval-$run-$port$q.txt"
        : >"$EVALS/eval-$run-$port$q.txt"; page || true
        read -r _ model url <<<"$(printf '%s\n' "${MODELS[@]}" | grep "^$port ")"
        [[ $url == claude ]] || load "$model" "$url" | sed "s/^/$port: /" || echo "$port: could not load $model" >&2
        samara/eval.py --url "http://127.0.0.1:$port" "${asks[@]}" $paid --out "$EVALS/eval-$run-$port$q.jsonl" \
            >"$EVALS/eval-$run-$port$q.txt" 2>&1 &
        e=$!
        while [[ $url != claude ]] && kill -0 "$e" 2>/dev/null; do   # LM Studio can drop it mid-run
            sleep 30
            load "$model" "$url" | sed "s/^/$port: /" || true
        done
        wait "$e" || echo "$port: eval failed, see that file" >&2
        page || true
    done
}
claude=$(for m in "${chosen[@]}"; do read -r port _ url <<<"$m"; if [[ $url == claude ]]; then echo "$port"; fi; done | xargs)
servers=$(for m in "${chosen[@]}"; do read -r _ _ url <<<"$m"; echo "$url"; done | sort -u)
queues=()
for server in $servers; do
    evaluate $(for m in "${chosen[@]}"; do read -r port _ url <<<"$m"; if [[ $url == "$server" ]]; then echo "$port"; fi; done) &
    queues+=($!)
done
(while sleep 60; do page || true; done) &   # the page between an eval's start and end
ticker=$!
wait "${queues[@]}"   # not a bare wait: the run.sh servers above are jobs too, and never end
kill "$ticker" 2>/dev/null || true
page || true
tail -n1 "$EVALS"/eval-"$run"-*"$q".txt
