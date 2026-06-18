"""
Claude Code PreToolUse hook — pytest quality gate.

Fires before every Bash tool call. If the command is a `git commit`,
runs `pytest tests/` first. Exits with code 2 to block the commit if any
test fails; exits 0 to allow all other commands through.

Exit codes (Claude Code hook contract):
  0  — allow the tool call to proceed
  2  — block the tool call and surface the stderr message to the user

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

    if result.returncode != 0:
        print(
            "\n[pre_commit_guard] pytest failed — commit blocked.\n"
            "Fix the failing tests before committing.",
            file=sys.stderr,
        )
        sys.exit(2)

    print("[pre_commit_guard] All tests passed — proceeding with commit.", flush=True)
    sys.exit(0)


if __name__ == "__main__":
    main()
