#!/usr/bin/env python3
"""elm-collector-config-backup: snapshot every LogicMonitor Collector's config
files (agent/wrapper/sbproxy/watchdog/website .conf) to a diffable, per-collector
tree for auditing, change-tracking, and disaster reference.

Companion to elm-backup.sh: that tool dumps alerting + collector *objects* as
JSONL; this one captures the collectors' actual *config-file* contents, which
elm-backup deliberately does not fetch (large, permission-gated blobs). Both are
read-only snapshots, NOT a restore mechanism -- LM has no bulk import. The value
is a diffable record of what each collector's config looked like. This tool does
not version anything itself -- each run overwrites the previous snapshot in place.
For history, either point a separate git repo at the backup dir and commit after
each run (`git log -p` then shows what changed), or use --date (below) to keep
dated snapshots.

Permissions:
  The config-file fields (wrapperConf/collectorConf/sbproxyConf/watchdogConf/
  websiteConf) are only returned to an API token whose `userPermission` on the
  collector includes `write` (Manage). A read-only token gets the literal string
  "{}" for each. This tool reads `userPermission` up front:
    * if NO collector is writable by this token, it aborts (exit 3) with an
      actionable message and writes nothing, rather than producing a tree of
      empty files;
    * otherwise it backs up every writable collector, SKIPS the read-only ones,
      and prints a readable/skipped summary. RBAC-scoped tokens (write on some
      collectors, read on others) back up exactly what they can.
  If the portal omits `userPermission` entirely, it falls back to gating on conf
  content (a collector with at least one non-empty conf is treated as readable).

Output:
  One directory per collector under
    DIR/ACCOUNT/[DATE/]collectors/<id>-<hostname>/
  with one decoded text file per non-empty conf:
    collectorConf  wrapperConf  sbproxyConf  watchdogConf  websiteConf
  ACCOUNT is the LM account_name (portal), resolved from elm itself (its request
  URL), not the credentials .ini. Hostnames are sanitised for the filesystem
  (the usual DOMAIN\\HOST form has its backslash/slash turned into '_').

  DIR defaults to $ELM_BACKUP_DIR or ~/elm-backup -- intentionally OUTSIDE this
  code repo so backups (which contain portal data) are never accidentally
  staged/committed. The tool refuses to write inside a git work tree unless --dir
  is given explicitly.

Examples:
  elm-collector-config-backup.py                       # default 'config' profile
  elm-collector-config-backup.py -p prod --date        # prod, history by date
  ELM_BACKUP_DIR=/srv/lm elm-collector-config-backup.py

Status messages go to stderr. Requires: elm on PATH.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

# The collector config-file fields. Edit to add/remove conf types.
CONF_FIELDS = ["wrapperConf", "collectorConf", "sbproxyConf",
               "watchdogConf", "websiteConf"]

# Exit codes: 0 ok; 1 fetch/parse error; 2 usage/precondition; 3 token cannot
# read ANY collector config (nothing written).
EXIT_OK, EXIT_ERR, EXIT_USAGE, EXIT_NOPERM = 0, 1, 2, 3


def err(*args):
    print(*args, file=sys.stderr)


def is_empty(v):
    """A real conf is never empty; LM returns "{}" (or "") when the field is not
    readable by this token, or genuinely absent for that conf type."""
    return v is None or str(v).strip() in ("", "{}")


def perms(row):
    return {p.strip().lower()
            for p in str(row.get("userPermission", "")).split(",") if p.strip()}


def safe(name):
    """DOMAIN\\HOST / FQDN -> filesystem-safe; collapse anything unusual to '_'."""
    return re.sub(r"[^A-Za-z0-9._-]+", "_", str(name)).strip("._") or "unknown"


def resolve_account(profile):
    """Label the backup by LM account_name, not the elm profile name (a profile
    can point at different accounts over time). `elm -f api` prints the request
    URL it builds (https://<account>.logicmonitor.com/...); one cheap probe
    yields the account with no .ini parsing. The Authorization line it also
    prints (HMAC signature) is discarded. Returns the account, or None."""
    try:
        out = subprocess.run(
            ["elm", "-p", profile, "-f", "api", "CollectorList", "-s1"],
            capture_output=True, text=True, check=False).stdout
    except OSError:
        return None
    m = re.search(r"^https://([^./]+)\.logicmonitor\.com/", out, re.M)
    return m.group(1) if m else None


def fetch_collectors(profile):
    """One bulk fetch: id + hostname + userPermission + all conf fields (-s0 =
    all collectors, up to LM's 1000 cap). Returns (rows, error_message)."""
    cmd = ["elm", "-p", profile, "-f", "json", "CollectorList", "-s0",
           "-f", "id,hostname,userPermission," + ",".join(CONF_FIELDS)]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        return None, (proc.stderr.strip() or f"elm exited {proc.returncode}")
    try:
        doc = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        return None, f"could not parse elm JSON: {e}"
    # elm -f json wraps rows as {"CollectorList": [...]}; tolerate a bare list.
    rows = doc.get("CollectorList", doc) if isinstance(doc, dict) else doc
    if not isinstance(rows, list):
        return None, "unexpected JSON shape (no CollectorList array)"
    return rows, None


def backup(rows, collectors_dir):
    """Split rows into per-collector conf files. Returns a summary dict."""
    total = len(rows)
    saw_perm = False        # did the API return userPermission at all?
    backed_up = files_out = 0
    skipped_ro = []         # read-only (no write perm)
    empty_write = []        # writable but confs still empty (odd)

    for row in rows:
        cid = row.get("id", "?")
        host = row.get("hostname") or row.get("description") or f"id{cid}"
        if "userPermission" in row:
            saw_perm = True
        writable = "write" in perms(row)

        confs = {f: row.get(f) for f in CONF_FIELDS}
        has_content = any(not is_empty(v) for v in confs.values())
        # Gate primarily on userPermission (authoritative, per-collector ->
        # RBAC safe). If the portal omits it entirely, fall back to conf content.
        if not saw_perm:
            writable = has_content

        if not writable:
            skipped_ro.append((cid, host))
            continue
        if not has_content:
            empty_write.append((cid, host))
            continue

        cdir = os.path.join(collectors_dir, f"{cid}-{safe(host)}")
        os.makedirs(cdir, exist_ok=True)
        for f in CONF_FIELDS:
            v = confs[f]
            if is_empty(v):
                continue
            text = v if isinstance(v, str) else json.dumps(v, indent=2)
            if not text.endswith("\n"):
                text += "\n"
            with open(os.path.join(cdir, f), "w") as out:
                out.write(text)
            files_out += 1
        backed_up += 1

    return dict(total=total, saw_perm=saw_perm, backed_up=backed_up,
                files_out=files_out, skipped_ro=skipped_ro,
                empty_write=empty_write)


def _sample(pairs, limit=8):
    shown = ", ".join(f"{c}({h})" for c, h in pairs[:limit])
    return shown + (" ..." if len(pairs) > limit else "")


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="elm-collector-config-backup.py",
        description="Snapshot every collector's config files to a diffable tree.")
    p.add_argument("-p", "--profile", default="config",
                   help="elm credential profile (default: config)")
    p.add_argument("-d", "--dir", default=None,
                   help="backup root dir (default: $ELM_BACKUP_DIR or ~/elm-backup)")
    p.add_argument("--date", action="store_true",
                   help="nest output under a UTC datestamp subdir (history)")
    args = p.parse_args(argv)

    if not shutil.which("elm"):
        err("elm-collector-config-backup: 'elm' not found in PATH")
        return EXIT_USAGE

    # Resolve root; remember whether the user chose it explicitly (guard below).
    root_explicit = args.dir is not None
    root = args.dir or os.environ.get("ELM_BACKUP_DIR") \
        or os.path.join(os.path.expanduser("~"), "elm-backup")

    # Safety net: refuse to write backups inside a git work tree unless the user
    # explicitly chose the location with --dir. Prevents accidentally committing
    # a portal backup into this (or any) repo.
    if not root_explicit:
        parent = os.path.dirname(os.path.abspath(root))
        inside = subprocess.run(
            ["git", "-C", parent, "rev-parse", "--is-inside-work-tree"],
            capture_output=True, text=True, check=False)
        if inside.returncode == 0 and inside.stdout.strip() == "true":
            repo = subprocess.run(
                ["git", "-C", parent, "rev-parse", "--show-toplevel"],
                capture_output=True, text=True, check=False).stdout.strip()
            err(f"elm-collector-config-backup: default dir '{root}' is inside "
                f"git repo '{repo}'.")
            err("  Refusing to write backups into a code repo. Set ELM_BACKUP_DIR "
                "or pass --dir DIR to a location outside any repo.")
            return EXIT_USAGE

    label = resolve_account(args.profile)
    if not label:
        err("elm-collector-config-backup: could not resolve account_name (probe "
            f"failed); falling back to profile name '{args.profile}'.")
        label = args.profile

    outdir = os.path.join(root, label)
    if args.date:
        from datetime import datetime, timezone
        outdir = os.path.join(outdir, datetime.now(timezone.utc).strftime("%Y-%m-%d"))
    collectors_dir = os.path.join(outdir, "collectors")

    err(f"elm-collector-config-backup: profile '{args.profile}' (account "
        f"'{label}') -> {collectors_dir}")

    rows, error = fetch_collectors(args.profile)
    if error:
        err(f"elm-collector-config-backup: CollectorList fetch failed: {error}")
        return EXIT_ERR

    s = backup(rows, collectors_dir)

    # Preflight abort: token could not read ANY collector's config.
    if s["backed_up"] == 0 and not s["empty_write"]:
        err(f"elm-collector-config-backup: no collector configs are readable by "
            f"profile's token ({s['total']} collector(s) seen).")
        if s["saw_perm"]:
            err("  userPermission on every collector is read-only (no 'write'). "
                "Collector config files require a Manage/write-level role.")
        else:
            err("  All conf fields came back empty ('{}'). The token likely lacks "
                "Manage/write permission on collectors.")
        err("  Nothing was written.")
        return EXIT_NOPERM

    err(f"elm-collector-config-backup: backed up {s['backed_up']}/{s['total']} "
        f"collector(s), {s['files_out']} conf file(s) -> {collectors_dir}")
    if s["skipped_ro"]:
        err(f"  skipped {len(s['skipped_ro'])} read-only collector(s): "
            + _sample(s["skipped_ro"]))
    if s["empty_write"]:
        err(f"  {len(s['empty_write'])} writable collector(s) returned empty "
            "configs (nothing to save): " + _sample(s["empty_write"]))
    err("elm-collector-config-backup: done.")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
