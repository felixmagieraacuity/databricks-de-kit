#!/usr/bin/env python3
"""
Claude Code PreToolUse hook — destructive operation guard.

Fires before every Bash, Write, or Edit tool call. Scans the command or
file content for dangerous operations and blocks them with exit code 2.

Blocked operations:
  DROP TABLE, DROP DATABASE, DROP SCHEMA
  rm -rf, dbfs rm -r
  TRUNCATE TABLE
  DELETE FROM ... (without WHERE clause)

Exit codes (Claude Code hook contract):
  0  — allow the tool call to proceed
  2  — block the tool call and surface the stderr message to the user
"""
import json
import re
import sys

DANGEROUS = [
    r"\bDROP\s+TABLE\b",
    r"\bDROP\s+DATABASE\b",
    r"\bDROP\s+SCHEMA\b",
    r"rm\s+-rf",
    r"dbfs\s+rm\s+-r",
    r"\bTRUNCATE\s+TABLE\b",
    r"\bDELETE\s+FROM\b(?!.*\bWHERE\b)",  # DELETE without WHERE
]


def main() -> None:
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        # If we can't parse the input, pass through — don't block
        print(raw, end="")
        sys.exit(0)

    # Extract command from tool_input (Bash) or content (Write/Edit)
    tool_input = data.get("tool_input", {})
    command = tool_input.get("command", "")
    if not command:
        # For Write/Edit hooks, check the content field
        command = tool_input.get("content", "")
    if not command:
        # Fallback: stringify the entire tool_input
        command = str(tool_input)

    for pattern in DANGEROUS:
        if re.search(pattern, command, re.IGNORECASE | re.DOTALL):
            print(
                f"[destructive_op_guard] BLOCKED: dangerous operation detected.",
                file=sys.stderr,
            )
            print(
                f"[destructive_op_guard] Matched pattern: {pattern}",
                file=sys.stderr,
            )
            print(
                f"[destructive_op_guard] Command (first 200 chars): {command[:200]}",
                file=sys.stderr,
            )
            print(
                "[destructive_op_guard] If intentional, run the command manually "
                "outside Claude Code.",
                file=sys.stderr,
            )
            sys.exit(2)

    # No dangerous patterns found — pass through
    print(raw, end="")
    sys.exit(0)


if __name__ == "__main__":
    main()
