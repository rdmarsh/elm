#!/usr/bin/env python3
"""elm-ask's read-only LogicMonitor tools as an MCP server, for Claude Code.

MCP over stdio is JSON-RPC, one message per line: the client (Claude Code)
starts this program, asks for the tool list, then calls tools. The tools,
the allowlist and secret removal are the same as the web page's (elm_tools.py).
One process is one conversation, so datasets ($d1, $d2, ...) last until the
client exits.

    claude mcp add elm -- python tools/elm-ask/mcp_server.py
"""

import functools
import json
import subprocess
import sys
from pathlib import Path

import elm_tools

HERE = Path(__file__).resolve().parent

# Claude Code keeps only the first 2048 characters of a server's instructions,
# so they only point at `guide`, which returns the web page's whole system
# prompt (how to work, how to answer) and elm-knowledge.md.
INSTRUCTIONS = ("Read-only tools for questions about a LogicMonitor portal. Before your first "
                "query, call guide once and follow it.")
GUIDE_TOOL = {
    "name": "guide",
    "description": "How to answer LogicMonitor questions with these tools, and the API traps found "
                   "in testing. Call it once, before the first query.",
    "inputSchema": {"type": "object", "properties": {}},
}


def guide():
    return "\n\n".join([
        "There is no web page here: show_table returns a Markdown table, and it only reaches "
        "the reader if you put it in your reply.",
        (HERE / "system_prompt.md").read_text(),
        "<elm_knowledge>\n" + (elm_tools.ELM_HOME / "elm-knowledge.md").read_text() + "\n</elm_knowledge>",
    ])


def markdown_table(event):
    """show_table's table as Markdown: the terminal's version of the page's table."""
    cell = lambda v: "" if v is None else str(v).replace("|", "\\|").replace("\n", " ")
    lines = ["| " + " | ".join(event["columns"]) + " |",
             "|" + "---|" * len(event["columns"])]
    lines += ["| " + " | ".join(cell(v) for v in row) + " |" for row in event["rows"]]
    return f"**{event['title']}** ({event['total']} rows)\n\n" + "\n".join(lines)


@functools.cache
def profile_problem():
    """Why this profile may not be used (checked once per process), or None."""
    return elm_tools.profile_status()["problem"]


def call_tool(session, name, args):
    """Run one tool; return (text, is_error)."""
    if name == "guide":
        return guide(), False
    problem = profile_problem()
    if problem:
        return problem, True
    handler = elm_tools.HANDLERS.get(name)
    if handler is None:
        return f"Unknown tool {name}", True
    try:
        text, event = handler(session, **args)
    except Exception as exc:  # errors go back to the model so it can correct itself
        return str(exc), True
    if event and event["type"] == "table":
        text = "Put this table in your reply as it is:\n\n" + markdown_table(event)
    return text, False


def reply(request, result):
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


def info():
    """What this server would answer with: elm, the profile, the portal."""
    version = subprocess.run(elm_tools.ELM_CMD + ["--version"], capture_output=True, text=True, timeout=60)
    status = elm_tools.profile_status()
    print(f"elm:      {version.stdout.strip() or version.stderr.strip()}")
    # With ELM_CONFIG the name is a path inside the container; its file name is the useful part.
    print(f"profile:  {Path(status['name']).name}")
    print(f"portal:   {status['account'] or '(unknown)'}")
    print(f"commands: {len(status['allowed'])} allowed" if status["restricted"] else "commands: every command (no allowed_commands)")
    if status["problem"]:
        print(f"problem:  {status['problem']}")


def main():
    if "--info" in sys.argv[1:]:
        return info()
    session = elm_tools.Session()
    tools = [GUIDE_TOOL] + [{"name": t["name"], "description": t["description"], "inputSchema": t["input_schema"]}
             for t in elm_tools.TOOLS]
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        if "id" not in request:
            continue  # a notification, e.g. notifications/initialized: no reply
        if method == "initialize":
            reply(request, {
                "protocolVersion": request["params"]["protocolVersion"],
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "elm", "version": "1"},
                "instructions": INSTRUCTIONS,
            })
        elif method == "tools/list":
            reply(request, {"tools": tools})
        elif method == "tools/call":
            text, is_error = call_tool(session, request["params"]["name"], request["params"].get("arguments") or {})
            reply(request, {"content": [{"type": "text", "text": text}], "isError": is_error})
        elif method == "ping":
            reply(request, {})
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"],
                              "error": {"code": -32601, "message": f"unknown method {method}"}}), flush=True)
    session.close()


if __name__ == "__main__":
    main()
