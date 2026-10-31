"""What a question is, decided in code before a model sees it.

A model left to decide got the same things wrong in every run (2026-10-31,
three models, about 330 answers): it treated a group as a device ("acme": "no
device, so no alerts"), looked up a write request instead of saying Samara is
read-only, and answered questions about named devices without looking at them.
Names and verbs can be checked exactly, so they are:

- a request to change something gets Samara's read-only answer, no model;
- names of devices, groups and collectors in the question are found in the
  portal and handed to the model, with the recipe for each;
- an answer that looked nothing up is sent back only when the question is
  about the portal, and if it still looks nothing up the named object's
  health recipe is run for it (agent._answer).
"""
import re
import threading
import time

import elm_tools

REFRESH_SECONDS = 900   # names change rarely; a new device is found within 15 minutes

# "Put web01 into SDT", "can you acknowledge the alerts", "please clear ...".
# At the start of the question (after "can you" and the like), so "which
# devices have alerting disabled?" and "add a percentage to that table" are
# questions, not requests.
WRITE = re.compile(
    r"^\s*(?:(?:can|could|would|will) you\s+|please\s+|pls\s+|i (?:want|need) (?:you )?to\s+|go\s+(?:and\s+)?)*"
    r"(put|place|schedule|set up|create|add|delete|remove|clear|ack|acknowledge|close|resolve|disable|enable|"
    r"restart|reboot|change|edit|update|rename|move|silence|mute|suppress|escalate|assign)\b"
    r"(?!.*\b(?:table|column|percentage|total|list)\b)", re.I)

# LogicMonitor's own words: "what does X mean" about one of these is answered
# from the knowledge base, with no lookup (system_prompt.md).
TERMS = {"sdt", "scheduled downtime", "downtime", "collector", "datasource", "data source", "eventsource",
         "configsource", "propertysource", "logicmodule", "dead", "host status", "nan", "instance",
         "escalation chain", "alert rule", "datapoint", "data point", "threshold", "flapping", "dead-collector",
         "auto-balance", "failover", "website check", "synthetic", "appliesto", "resource group"}
DEFINITION = re.compile(r"^\s*(?:what(?:'s| is| are| does)|whats|define|explain|what do you mean by)\b", re.I)

# Names too common to mean one thing in the portal ("All" is a group in many).
COMMON = {"all", "test", "tests", "prod", "production", "dev", "default", "other", "others", "linux",
          "windows", "network", "networks", "servers", "server", "devices", "device", "website", "websites",
          "collector", "collectors", "group", "groups", "alerts", "status", "issue", "issues", "service",
          "services", "level", "class", "type", "site", "environment", "active", "azure", "aws", "cloud",
          "kubernetes", "customer", "customers", "sandbox", "lab", "core", "monitoring", "ping", "http",
          "https", "snmp", "wmi", "today", "week", "month"}
MIN_NAME = 3   # "web" is too common to count, but COMMON catches those; "lux" is a device

_names, _when, _lock = [], 0.0, threading.Lock()


def names():
    """[(name, kind, id, label)] of every device, group and collector, cached."""
    global _names, _when
    with _lock:
        if _names and time.time() - _when < REFRESH_SECONDS:
            return _names
        found = []
        for kind, command, fields in (("device", "DeviceList", ["id", "displayName"]),
                                      ("group", "DeviceGroupList", ["id", "name", "fullPath"]),
                                      ("collector", "CollectorList", ["id", "description", "hostname"])):
            try:
                rows = page(command, fields)
            except elm_tools.Refused:
                continue   # not allowed, or the portal cannot be reached: route without them
            for r in rows:
                label = r.get("fullPath") or r.get("displayName") or r.get("description") or r.get("name")
                given = {r.get(f) for f in fields if f != "id"}
                if kind == "collector":
                    # "lmcollect-sb1 (nick dev)", "DOMAIN\\HOST", "host.example.com": people say the host
                    for n in list(given):
                        if isinstance(n, str):
                            given.add(re.split(r"\s+\(", n)[0].split("\\")[-1].split(".")[0])
                for n in given:
                    if isinstance(n, str) and len(n) >= MIN_NAME and n.lower() not in COMMON:
                        found.append((n, kind, r.get("id"), label))
        _names, _when = found, time.time()
        return _names


def page(command, fields):
    """Every row of one list command (paged past elm's 1000)."""
    import json
    rows, offset = [], 0
    while True:
        lines = elm_tools.fetch(command, fields=fields, size=0, offset=offset)[0]
        rows += [json.loads(l) for l in lines]
        if len(lines) < elm_tools.MAX_ROWS or offset >= 20 * elm_tools.MAX_ROWS:
            return rows
        offset += elm_tools.MAX_ROWS


def found(question):
    """The portal's devices, groups and collectors named in the question, longest name first.

    A name counts when it is a whole word in the question, case ignored:
    "acme" in "is anything down at acme?", a group path, a device's display
    name. "collector 101" is collector id 101.
    """
    q = question.lower()
    hits, taken = [], []
    for name, kind, id_, label in sorted(names(), key=lambda n: -len(n[0])):
        n = name.lower().strip("/")
        m = re.search(rf"(?<![\w.\-]){re.escape(n)}(?![\w\-]|\.\w)", q)
        if not m or any(a <= m.start() < b and (m.start(), m.end()) != (a, b) for a, b in taken):
            continue   # inside a longer name already found ("acme" in "Customers/acme")
        taken.append((m.start(), m.end()))   # the same name may still be a device and a collector
        if not any(h["kind"] == kind and h["id"] == id_ for h in hits):
            hits.append({"kind": kind, "name": name, "id": id_, "label": label})
    # A collector usually runs on a device of the same name: "luna" is the
    # device unless the question says collector, and then only the collector.
    said = bool(re.search(r"\bcollectors?\b", q))
    both = {h["name"].lower() for h in hits if h["kind"] == "collector"} & {h["name"].lower() for h in hits if h["kind"] == "device"}
    # "luna's collector" is the device's collector: device_collector, not the collector named luna.
    own = {n for n in both if re.search(rf"\b{re.escape(n)}(?:'|’)s collector", q)}
    hits = [h for h in hits if h["name"].lower() not in both
            or (h["kind"] == "collector") == (said and h["name"].lower() not in own)]
    for m in re.finditer(r"\bcollector\s+(?:id\s+)?(\d+)\b", q):
        if not any(h["kind"] == "collector" and str(h["id"]) == m.group(1) for h in hits):
            hits.append({"kind": "collector", "name": m.group(1), "id": int(m.group(1)), "label": f"collector {m.group(1)}"})
    return hits


def route(question):
    """What the question is: {"write": the verb or None, "term": bool, "found": [...]}."""
    w = WRITE.search(question)
    q = question.lower()
    term = bool(DEFINITION.search(question)) and any(re.search(rf"\b{re.escape(t)}\b", q) for t in TERMS)
    return {"write": w.group(1).lower() if w else None, "term": term, "found": found(question)}


# The recipe run for a named object when the model will not look it up.
HEALTH = {"device": "device_health", "group": "group_health", "collector": "collector_health"}


def hint(hits):
    """The line added to the question: what Samara found, and the recipe for it."""
    said = []
    for h in hits[:6]:
        where = f" ({h['label']})" if h["label"] and h["label"] != h["name"] else ""
        said.append(f"'{h['name']}' is a {h['kind']}{where}: recipe {HEALTH[h['kind']]}, or another {h['kind']} recipe")
    return "(Samara found in the portal: " + "; ".join(said) + ".)"


def read_only(verb, portal):
    """Samara's answer to a request to change something: no model, no query."""
    where = portal or "the portal"
    return (f"I can't {verb} anything: Samara is read-only, so it can look at {where} but never change it. "
            f"Do it in the LogicMonitor portal, or ask someone who has access. I can tell you what is "
            f"there now: ask me about it.")
