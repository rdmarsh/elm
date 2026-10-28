#!/usr/bin/env python3
"""elm-swagger-gaps: find the fields LM returns that its swagger leaves out.

Usage:
  elm-swagger-gaps.py [-p PROFILE] [--only CMD,...] [--seed NAME=VALUE ...] [--write]

Runs every elm command once against a portal and compares the fields that come
back with the ones the swagger documents (a subtype's included, and what
swagger.undocumented.json already adds). Ids a command needs (--deviceId,
--hdsId, --id, ...) are taken from the first record of the list one level up
the path: DeviceDatasourceList for --hdsId, after DeviceList for --deviceId.
--seed pins one instead, e.g. --seed deviceId=1234 for a device that has the
datasources you want covered.

Output: one gap per line on stdout, "COMMAND FIELD TYPE", so it pipes. On
stderr, each command's outcome (rows, none, skipped and why) and a count.
With --write, the gaps are added to swagger.undocumented.json under the
record's definition, which `make` turns into --info lines and fields -F and
-f accept. Run it after `make swagger`, and with more than one profile: a
token with more rights answers more commands.

Only field names and types are read from the results, never printed values:
a token with manage rights sees collector tokens and config.

Commands it cannot check: those the portal has no records for, those needing
an id no list gives, and those whose swagger describes no response at all.
They are listed on stderr.

Examples:
  tools/elm-swagger-gaps.py -p sandbox
  tools/elm-swagger-gaps.py -p sandbox_manage --only CollectorList,CollectorById
  tools/elm-swagger-gaps.py -p sandbox --write && make

Run from anywhere; it reads _defs/ and the swagger snapshots from the repo.
Requires: elm, a built _defs/ (make)
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
sys.path.insert(0, str(ROOT))
import mkinfo  # noqa: E402  (needs the repo as its working directory)

UNDOCUMENTED = ROOT / "swagger.undocumented.json"
# GETs that download a file rather than return records.
SKIP = {"CollectorInstaller"}
KINDS = {bool: "boolean", int: "integer", float: "number", str: "string", list: "array", dict: "object"}


def err(*args):
    print(*args, file=sys.stderr, flush=True)


class Portal:
    def __init__(self, profile, commands):
        self.profile = profile
        self.by_path = {d["path"]: d for d in commands.values()}
        self.ids = {}

    def run(self, d, args, size=5):
        """The records one command returns, and its exit code."""
        cmd = ["elm"] + (["-p", self.profile] if self.profile else []) + ["-f", "jsonl", d["command"]]
        if any(o["name"] == "size" for o in d["options"]):
            cmd += ["-s", str(size)]
        try:
            p = subprocess.run(cmd + args, capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            return [], "timed out"
        rows = []
        for line in p.stdout.splitlines():
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
        return rows, (None if p.returncode == 0 else f"exit {p.returncode}")

    def args_for(self, d, seeds):
        """The --NAME VALUE pairs a command's path needs, or (None, why)."""
        args, filled = [], {}
        for name in re.findall(r"\{(\w+)\}", d["path"]):
            if name in seeds:
                value = seeds[name]
            else:
                # the list one level up: /a/{x}/b/{name} comes from /a/{x}/b
                parent = d["path"].split("/{" + name + "}", 1)[0]
                value = self.first_id(parent, filled)
                if value is None:
                    return None, f"no id for {name} (from {parent})"
            filled[name] = value
            args += [f"--{name}", str(value)]
        required = [o["name"] for o in d["options"] if o.get("required") and o.get("in") != "path"]
        if required:
            return None, f"needs {', '.join(required)}"
        return args, None

    def first_id(self, path, filled):
        key = (path, tuple(sorted(filled.items())))
        if key not in self.ids:
            d = self.by_path.get(path)
            value = None
            if d:
                args = [a for k, v in filled.items() if "{" + k + "}" in path for a in (f"--{k}", str(v))]
                rows, _ = self.run(d, args + ["-f", "id"], 1)
                value = rows[0].get("id") if rows else None
            self.ids[key] = value
        return self.ids[key]


def record_definition(path, paths, definitions):
    """The swagger definition one returned record is: a page's item, or the response itself."""
    responses = paths.get(path, {}).get("get", {}).get("responses", {})
    schema = (responses.get("200") or responses.get("default") or {}).get("schema", {})
    items = mkinfo.schema_properties(schema, definitions).get("items", {})
    ref = items.get("items", {}).get("$ref", "") if items.get("type") == "array" else schema.get("$ref", "")
    return ref.rsplit("/", 1)[-1] or None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("-p", "--profile", help="elm credential profile (default: elm's)")
    ap.add_argument("--only", help="comma-separated commands to check")
    ap.add_argument("--seed", action="append", default=[], metavar="NAME=VALUE",
                    help="use this id for a path parameter, e.g. deviceId=1234")
    ap.add_argument("--write", action="store_true", help="add the gaps to swagger.undocumented.json")
    opts = ap.parse_args()

    seeds = dict(s.split("=", 1) for s in opts.seed)
    commands = {d["command"]: d for d in (json.loads(f.read_text()) for f in sorted(Path("_defs").glob("[A-Z]*.json")))}
    if not commands:
        sys.exit("No _defs/ found: run make first.")
    only = set(opts.only.split(",")) if opts.only else None
    paths, definitions = mkinfo.load_swagger()
    portal = Portal(opts.profile, commands)

    gaps = {}            # definition -> {field: type}
    counts = {}
    for name, d in sorted(commands.items()):
        if only and name not in only:
            continue
        if name in SKIP:
            outcome = "skipped (downloads a file)"
        else:
            known = set(mkinfo.response_fields(d["path"], paths, definitions)) \
                | mkinfo.subtype_fields(d["path"], paths, definitions)
            args, why = portal.args_for(d, seeds)
            if args is None:
                outcome = f"skipped ({why})"
            elif not known:
                outcome = "not checked (the swagger describes no response)"
            else:
                rows, failed = portal.run(d, args)
                returned = set().union(*(r.keys() for r in rows)) if rows else set()
                if failed:
                    outcome = f"failed ({failed})"
                elif not rows:
                    outcome = "none (no records here)"
                elif len(returned - known) > len(returned) / 2:
                    # V4Metadata, DeltaIdWithDevices: the records are wrapped another
                    # way. Real gaps are a few fields of a record, never most of it.
                    outcome = "not checked (the response is shaped unlike the swagger)"
                else:
                    extra = sorted(returned - known)
                    outcome = f"rows, {len(extra)} undocumented" if extra else "rows, all documented"
                    definition = record_definition(d["path"], paths, definitions)
                    for field in extra:
                        kind = next((KINDS.get(type(r[field])) for r in rows if r.get(field) is not None), None)
                        print(name, field, kind or "unknown", flush=True)
                        if definition:
                            gaps.setdefault(definition, {})
                            if kind or field not in gaps[definition]:
                                gaps[definition][field] = kind or "string"
        err(f"{name}: {outcome}")
        counts[outcome.split(" (")[0].split(",")[0]] = counts.get(outcome.split(" (")[0].split(",")[0], 0) + 1

    err("; ".join(f"{n} {k}" for k, n in sorted(counts.items())))
    if opts.write and gaps:
        spec = json.loads(UNDOCUMENTED.read_text())
        note = f"Not in LM's swagger: seen in API responses, {datetime.date.today()}."
        added = 0
        for definition, fields in sorted(gaps.items()):
            props = spec.setdefault("definitions", {}).setdefault(definition, {"properties": {}})["properties"]
            for field, kind in sorted(fields.items()):
                if field not in props:
                    props[field] = {"type": kind, "description": note} | ({"items": {}} if kind == "array" else {})
                    added += 1
        UNDOCUMENTED.write_text(json.dumps(spec, indent=2) + "\n")
        err(f"wrote {added} field(s) to {UNDOCUMENTED.name}: run make to use them")


if __name__ == "__main__":
    main()
