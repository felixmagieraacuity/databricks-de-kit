"""
Claude Code PreToolUse hook — pytest quality gate.

Fires before every Bash tool call. If the command is a `git commit`,
runs `pytest tests/` first. Exits with code 2 to block the commit only on
an actual test failure; missing/empty test suites are let through with a
warning so repos without tests can still commit.

Exit codes (Claude Code hook contract):
  0  — allow the tool call to proceed
  2  — block the tool call and surface the stderr message to the user

pytest exit codes (see pytest docs):
  0 — all tests passed                    -> allow
  1 — tests were collected and failed     -> block (exit 2)
  2 — test execution was interrupted      -> allow, warn
  3 — internal pytest error               -> allow, warn
  4 — pytest usage error (e.g. bad args)  -> allow, warn
  5 — no tests were collected             -> allow, warn

Configuration:
  Set the TEST_PATH environment variable to override the default test
  directory. Defaults to ./tests/ relative to the current working directory.
"""
import json
import os
import subprocess
import sys


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        sys.exit(0)

    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})

    if tool_name != "Bash":
        sys.exit(0)

    command = tool_input.get("command", "")

    # Only intercept actual commits — not git status, git log, etc.
    if "git commit" not in command:
        sys.exit(0)

    # Check if pytest is available
    check = subprocess.run(
        [sys.executable, "-m", "pytest", "--version"],
        capture_output=True,
    )
    if check.returncode != 0:
        print(
            "[pre_commit_guard] WARNING: pytest not found — skipping test gate.\n"
            "Install it with: pip install pytest",
            file=sys.stderr,
        )
        sys.exit(0)

    # Determine test path (configurable via env var)
    test_path = os.environ.get("TEST_PATH", "tests/")

    print(f"[pre_commit_guard] Running pytest {test_path} ...", flush=True)

    result = subprocess.run(
        [sys.executable, "-m", "pytest", test_path, "-v", "--tb=short"],
        capture_output=False,
    )

    if result.returncode == 1:
        print(
            "\n[pre_commit_guard] pytest failed — commit blocked.\n"
            "Fix the failing tests before committing.",
            file=sys.stderr,
        )
        sys.exit(2)

    if result.returncode == 0:
        print("[pre_commit_guard] All tests passed — proceeding with commit.", flush=True)
        sys.exit(0)

    if result.returncode == 5:
        print(
            f"[pre_commit_guard] No tests collected under {test_path} — proceeding with commit.",
            file=sys.stderr,
        )
        sys.exit(0)

    if result.returncode == 4:
        print(
            "[pre_commit_guard] pytest usage error (e.g. missing test path) — "
            "proceeding with commit.",
            file=sys.stderr,
        )
        sys.exit(0)

    print(
        f"[pre_commit_guard] WARNING: pytest exited with code {result.returncode} "
        "(interrupted or internal error) — proceeding with commit.",
        file=sys.stderr,
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
