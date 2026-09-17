#!/usr/bin/env python3
"""Build the text shown by `elm COMMAND --info` and store it in each _defs/COMMAND.json.

Run by make after the per-command definitions are generated. For every command
it combines three sources into one compact, plain-text reference:

  _defs/COMMAND.json      path, summary and parameters (from the swagger)
  elm-notes.yaml          verified notes, gotchas and patterns for the command
  swagger.*.json          the documented response fields and their descriptions

The command template renders the text into _cmds/COMMAND.py, so the built
binary needs no data files at runtime. Notes come before fields and override
them: the swagger descriptions are LogicMonitor's and are sometimes incomplete
or wrong.

The text is written to be read by people and by AI assistants, so it is kept
short: one line per field, descriptions trimmed, no repeated boilerplate.

A definition file is only rewritten when its info text changes, so editing one
command's notes re-renders only that command.
"""

import json
import re
import sys
from pathlib import Path

import yaml

DEFS = Path("_defs")
NOTES = Path("elm-notes.yaml")
SWAGGERS = [Path("swagger.documented.json"), Path("swagger.undocumented.json")]

MAX_DESCRIPTION = 90          # characters of a swagger field description
PAGING = {"fields", "size", "offset", "filter"}
STANDARD_FLAGS = "[-s N] [-o N] [-f FIELD,...] [-F FILTER] [-S SORT] [-c] [-C]"


def clean(text):
    """Collapse whitespace; None becomes ''."""
    return " ".join(str(text or "").split())


def trim(text, limit=MAX_DESCRIPTION):
    text = clean(text)
    return text if len(text) <= limit else text[: limit - 3].rstrip() + "..."


# --- swagger -----------------------------------------------------------------

def load_swagger():
    """Paths and definitions from both snapshots (documented wins for schemas)."""
    paths, definitions = {}, {}
    for swagger in SWAGGERS:
        spec = json.loads(swagger.read_text())
        for path, ops in spec.get("paths", {}).items():
            paths.setdefault(path, ops)
        definitions.update(spec.get("definitions", {}))
    return paths, definitions


def schema_properties(schema, definitions, seen=()):
    """Flatten $ref and allOf into {field: property}."""
    if "$ref" in schema:
        name = schema["$ref"].rsplit("/", 1)[-1]
        if name in seen:
            return {}
        return schema_properties(definitions.get(name, {}), definitions, seen + (name,))
    props = {}
    for part in schema.get("allOf", []):
        props.update(schema_properties(part, definitions, seen))
    props.update(schema.get("properties", {}))
    return props


def field_type(prop):
    kind = prop.get("type", "")
    if "$ref" in prop or "allOf" in prop:
        kind = "object"
    if kind == "array":
        item = prop.get("items", {})
        inner = item["$ref"].rsplit("/", 1)[-1] if "$ref" in item else item.get("type", "")
        kind = f"array of {inner}" if inner else "array"
    return kind or "object"


def response_fields(api_path, paths, definitions):
    """{field: (type, description)} for one record returned by GET api_path."""
    responses = paths.get(api_path, {}).get("get", {}).get("responses", {})
    schema = (responses.get("200") or responses.get("default") or {}).get("schema", {})
    props = schema_properties(schema, definitions)
    items = props.get("items", {})
    if items.get("type") == "array" and set(props) <= {"total", "searchId", "items", "isMin"}:
        props = schema_properties(items.get("items", {}), definitions)   # a page: describe one item
    return {name: (field_type(p), trim(p.get("description"))) for name, p in props.items()}


# --- elm-notes.yaml ------------------------------------------------------------

def note_blocks(text):
    """{command: raw text of its top-level block}, to recover YAML comments."""
    blocks, name, lines = {}, None, []
    for line in text.splitlines():
        match = re.match(r"^([A-Za-z_][\w]*):\s*$", line)
        if match:
            if name:
                blocks[name] = lines
            name, lines = match.group(1), []
        elif name:
            lines.append(line)
    if name:
        blocks[name] = lines
    return blocks


def commented_items(block, section):
    """{key: (value, comment)} for the direct children of `section:` in a raw block."""
    items, inside = {}, False
    for line in block:
        if re.match(rf"^  {section}:\s*$", line):
            inside = True
            continue
        if inside:
            if line.strip() and not line.startswith("    "):
                break
            match = re.match(r"^    ([\w.]+):\s*([^#]*?)\s*(?:#\s*(.*))?$", line)
            if match:
                items[match.group(1)] = (match.group(2).strip(), clean(match.group(3)))
    return items


# --- the info text -------------------------------------------------------------

def render_plain(key, value, indent=""):
    """Free-form note sections as indented plain text (no YAML quoting)."""
    if isinstance(value, dict):
        lines = [f"{indent}{key}:"]
        for k, v in value.items():
            lines.extend(render_plain(k, v, indent + "  "))
        return lines
    if isinstance(value, list):
        return [f"{indent}{key}:"] + [f"{indent}  - {clean(v)}" for v in value]
    text = str(value).strip()
    if "\n" in text:
        return [f"{indent}{key}:"] + [f"{indent}  {line}".rstrip() for line in text.splitlines()]
    return [f"{indent}{key}: {text}"]


def as_list(value):
    if not value:
        return []
    return value if isinstance(value, list) else [value]


def build_info(definition, note, block, fields):
    command = definition["command"]
    out = [f"{command}: {clean(definition.get('summary'))}", f"GET {definition['path']}", ""]

    options = [o for o in definition["options"] if o["name"] not in PAGING]
    has_paging = any(o["name"] == "size" for o in definition["options"])
    required = [o for o in options if o.get("required") or o.get("in") == "path"]
    usage = " ".join(f"--{o['name']} {o.get('type', 'VALUE').upper()}" for o in required)
    flags = STANDARD_FLAGS if has_paging else "[-f FIELD,...] [-S SORT] [-c] [-C]"
    out.append(f"Usage: elm [GLOBAL FLAGS] {command} {usage} {flags}".replace("  ", " "))

    note = note if isinstance(note, dict) else ({"note": note} if note else {})
    param_comments = commented_items(block, "required_params")
    unique = note.get("unique_options") or {}
    unique_text = ""
    if not isinstance(unique, dict):          # some entries describe options in prose
        unique_text, unique = clean(unique), {}
    optional = [o for o in options if o not in required]
    if required or optional:
        out.append("Parameters:")
        for o in required + optional:
            text = clean(unique.get(o["name"])) or param_comments.get(o["name"], ("", ""))[1]
            text = re.sub(rf"^--{re.escape(o['name'])}\b[^—]{{0,60}}—\s*", "", text)   # drop a repeated "--flag TYPE —"
            flag = "required" if o in required else "optional"
            out.append(f"  --{o['name']} {o.get('type', '')} ({flag})" + (f": {text}" if text else ""))
    if unique_text:
        out.append(f"  {unique_text}")
    out.append("")

    if note:
        out.append("Notes (elm-notes.yaml, from live testing; they take precedence over the field list):")
        if note.get("note"):
            out.append(f"- {clean(note['note'])}")
        for gotcha in as_list(note.get("gotchas")):
            out.append(f"- {clean(gotcha)}")
        for pattern in as_list(note.get("filter_patterns")):
            out.append(f"- filter: {clean(pattern)}")
        patterns = note.get("patterns") or {}
        if not isinstance(patterns, dict):
            patterns = {f"{i + 1}": p for i, p in enumerate(as_list(patterns))}
        if patterns:
            out.append("Patterns:")
            for name, body in patterns.items():
                body = str(body).strip()
                if "\n" in body:
                    out.append(f"  {name}:")
                    out.extend(f"    {line}" for line in body.splitlines())
                else:
                    out.append(f"  {name}: {body}")
        known = {"path", "note", "gotchas", "filter_patterns", "patterns", "key_fields",
                 "required_params", "unique_options"}
        for key, value in note.items():
            if key not in known:
                out.extend(render_plain(key, value))
        out.append("")

    key_fields = commented_items(block, "key_fields")
    names = sorted(set(fields) | set(key_fields), key=str.lower)
    if names:
        out.append("Fields (name: type - description; [notes] = elm-notes.yaml, otherwise the swagger):")
        for name in names:
            kind, description = fields.get(name, ("", ""))
            note_type, note_comment = key_fields.get(name, ("", ""))
            if note_type and not note_type.startswith(("{", "[")) and " " not in note_type:
                kind = kind or note_type
            if note_comment:
                description = f"[notes] {note_comment}"
            elif name not in fields:
                description = "[notes] not in the swagger"
            out.append(f"  {name}: {kind}" + (f" - {description}" if description else ""))
    else:
        out.append("Fields: not described in the swagger; run with -s1 to see what comes back.")

    return "\n".join(out).rstrip() + "\n"


def main():
    paths, definitions = load_swagger()
    notes_text = NOTES.read_text() if NOTES.exists() else ""
    notes = yaml.safe_load(notes_text) or {}
    blocks = note_blocks(notes_text)

    changed = 0
    for def_file in sorted(DEFS.glob("[A-Z]*.json")):
        definition = json.loads(def_file.read_text())
        command = definition["command"]
        fields = response_fields(definition["path"], paths, definitions)
        info = build_info(definition, notes.get(command), blocks.get(command, []), fields)
        if definition.get("info") != info:
            definition["info"] = info
            def_file.write_text(json.dumps(definition, separators=(",", ":")) + "\n")
            changed += 1
    print(f"mkinfo: {changed} command definition(s) updated", file=sys.stderr)


if __name__ == "__main__":
    main()
