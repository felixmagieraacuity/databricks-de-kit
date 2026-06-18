"""
Claude Code PostToolUse hook — sqlfluff SQL formatter.

Fires after every Write or Edit tool call. If the modified file ends in
.sql, runs `sqlfluff fix --dialect sparksql` to auto-format it in place.

Exit codes (Claude Code hook contract):
  0  — proceed normally (always; formatting failures are advisory only)
"""
import json
import subprocess
import sys


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        sys.exit(0)

    tool_input = data.get("tool_input", {})
    file_path = tool_input.get("file_path", "")

    if not file_path.lower().endswith(".sql"):
        sys.exit(0)

    print(f"[sqlfluff_guard] Formatting {file_path} ...", flush=True)

    # Check if sqlfluff is available — graceful degradation if not installed
    check = subprocess.run(
        [sys.executable, "-m", "sqlfluff", "--version"],
        capture_output=True,
    )
    if check.returncode != 0:
        print(
            "[sqlfluff_guard] WARNING: sqlfluff not found — skipping SQL formatting.\n"
            "Install it with: pip install sqlfluff",
            file=sys.stderr,
        )
        sys.exit(0)

    try:
        result = subprocess.run(
            [
                sys.executable, "-m", "sqlfluff", "fix",
                "--dialect", "sparksql",
                "--force", file_path,
            ],
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        print(
            "[sqlfluff_guard] WARNING: sqlfluff not found — skipping SQL formatting.\n"
            "Install it with: pip install sqlfluff",
            file=sys.stderr,
        )
        sys.exit(0)

    # sqlfluff exit codes: 0 = no changes needed, 1 = file(s) fixed, other = error
    if result.returncode not in (0, 1):
        print(
            f"[sqlfluff_guard] Error (exit {result.returncode}):\n{result.stderr.strip()}",
            file=sys.stderr,
        )
    else:
        status = "no changes needed" if result.returncode == 0 else "fixed"
        print(f"[sqlfluff_guard] {file_path} — {status}", flush=True)

    sys.exit(0)


if __name__ == "__main__":
    main()
