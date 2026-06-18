#!/usr/bin/env python3
"""
Claude Code Stop hook — session learning extractor.

Triggered at the end of each Claude Code session. Detects DE-relevant
sessions, analyzes the transcript with Claude, and writes a structured
session summary to docs/learnings/session_YYYYMMDD.md for review.

Output path is configurable via the LEARNINGS_DIR environment variable.
Default: ./docs/learnings/
"""
import json
import os
import sys
from datetime import datetime
from pathlib import Path

DE_KEYWORDS = [
    "databricks", "fabric", "dlt", "delta lake", "pipeline", "spark",
    "pyspark", "unity catalog", "medallion", "bronze", "silver", "gold",
    "lakehouse", "data lake", "ingestion", "transformation", "etl", "elt",
    "data quality", "expectations", "mcp server", "warehouse", "autoloader",
    "delta live tables", "lakeflow", "structured streaming", "data vault",
]

NOVELTY_EMOJI = {"new": "[NEW]", "confirms_existing": "[OK]", "extends_existing": "[+]"}
CONFIDENCE_STARS = {"high": "***", "medium": "**", "low": "*"}


def _parse_transcript(raw: str) -> list:
    """Parse transcript as a JSON array or JSONL (one object per line)."""
    raw = raw.strip()
    try:
        parsed = json.loads(raw)
        return parsed if isinstance(parsed, list) else [parsed]
    except json.JSONDecodeError:
        pass
    decoder = json.JSONDecoder()
    messages = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj, _ = decoder.raw_decode(line)
            messages.append(obj)
        except json.JSONDecodeError:
            continue
    return messages


def is_de_relevant(transcript_json: str) -> bool:
    text = transcript_json.lower()
    return sum(kw in text for kw in DE_KEYWORDS) >= 2


def extract_text(transcript: list) -> str:
    parts = []
    for msg in transcript:
        role = msg.get("role", "unknown")
        content = msg.get("content", "")
        if isinstance(content, str):
            parts.append(f"[{role}]: {content}")
        elif isinstance(content, list):
            for item in content:
                if isinstance(item, dict) and item.get("type") == "text":
                    parts.append(f"[{role}]: {item['text']}")
    return "\n\n".join(parts)


def analyze_with_claude(session_text: str) -> dict:
    try:
        import anthropic
    except ImportError:
        print(
            "[extract_learnings] ERROR: anthropic package not installed. "
            "Run: pip install anthropic",
            file=sys.stderr,
        )
        return {"is_relevant": False}

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print(
            "[extract_learnings] ERROR: ANTHROPIC_API_KEY not set — skipping learning extraction.",
            file=sys.stderr,
        )
        return {"is_relevant": False}

    client = anthropic.Anthropic(api_key=api_key)

    prompt = f"""You are a technical writer for a Data Engineering best practices knowledge base.
Analyze this Claude Code session and extract valuable learnings worth documenting.

## Session Transcript (truncated):
{session_text[:14000]}

## Output Requirements:
Return ONLY a valid JSON object with this exact structure:
{{
  "is_relevant": true,
  "session_summary": "2-3 sentences: what was done, what was the goal",
  "topics": ["topic1", "topic2"],
  "tools_used": ["Databricks MCP", "DLT CLI", "Unity Catalog"],
  "pitfalls_discovered": [
    "Specific gotcha or workaround discovered (only if real, concrete finding)"
  ],
  "best_practices_validated": [
    "Specific practice that worked well (only if real, concrete)"
  ],
  "learnings": [
    {{
      "title": "Short descriptive title",
      "section": "Bronze / Silver / Gold / CDC / Schema / Performance / Other",
      "finding": "What was discovered, validated, or disproven",
      "proposed_text": "Ready-to-document snippet (1-3 sentences, precise)",
      "novelty": "new | confirms_existing | extends_existing",
      "confidence": "high | medium | low"
    }}
  ]
}}

Rules:
- Only include high-value, concrete learnings backed by actual session evidence
- Skip generic observations that are already well-known
- proposed_text must be polished, professional, and ready to add to documentation
- If session has no meaningful new learnings, set is_relevant to false
"""

    response = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=4096,
        system="You extract structured technical learnings from engineering sessions. Output only valid JSON.",
        messages=[{"role": "user", "content": prompt}],
    )

    raw = response.content[0].text.strip()
    start = raw.find("{")
    end = raw.rfind("}") + 1
    if start < 0 or end <= start:
        return {"is_relevant": False}
    return json.loads(raw[start:end])


def render_summary(analysis: dict, session_id: str, output_path: Path) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M")
    lines = [
        "# Session Learning Summary",
        "",
        f"**Date:** {ts}",
        f"**Session:** {session_id}",
        f"**Status:** PENDING REVIEW",
        "",
        "---",
        "",
        "## Session Summary",
        "",
        analysis.get("session_summary", ""),
        "",
        f"**Topics:** {', '.join(analysis.get('topics', []))}",
        f"**Tools:** {', '.join(analysis.get('tools_used', []))}",
        "",
    ]

    pitfalls = analysis.get("pitfalls_discovered", [])
    if pitfalls:
        lines += ["## Pitfalls & Gotchas", ""]
        for p in pitfalls:
            lines.append(f"- {p}")
        lines.append("")

    best_practices = analysis.get("best_practices_validated", [])
    if best_practices:
        lines += ["## Best Practices Validated", ""]
        for bp in best_practices:
            lines.append(f"- {bp}")
        lines.append("")

    learnings = analysis.get("learnings", [])
    if learnings:
        lines += [
            "---",
            "",
            f"## Learnings ({len(learnings)} item{'s' if len(learnings) != 1 else ''})",
            "",
        ]
        for i, lr in enumerate(learnings, 1):
            emoji = NOVELTY_EMOJI.get(lr.get("novelty", ""), "")
            stars = CONFIDENCE_STARS.get(lr.get("confidence", ""), "")
            novelty_label = lr.get("novelty", "").replace("_", " ").title()

            lines += [
                f"### {i}. {lr.get('title', '')} {emoji}",
                "",
                f"**Section:** {lr.get('section', 'TBD')} | "
                f"**Confidence:** {stars} | **Type:** {novelty_label}",
                "",
                "**Finding:**",
                lr.get("finding", ""),
                "",
                "**Proposed documentation text:**",
                "```",
                lr.get("proposed_text", ""),
                "```",
                "",
                "**Decision:**",
                "- [ ] APPROVE — add to documentation",
                "- [ ] REJECT",
                "- [ ] MODIFY (edit proposed text above, then approve)",
                "",
            ]

    lines += [
        "---",
        "",
        f"*Generated by extract_learnings.py at {ts}*",
    ]

    output_path.write_text("\n".join(lines), encoding="utf-8")


def main():
    raw_stdin = sys.stdin.read().strip()
    if not raw_stdin:
        sys.exit(0)

    try:
        data = json.loads(raw_stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    transcript_path = data.get("transcript_path")
    session_id = data.get("session_id", "unknown")

    if not transcript_path:
        sys.exit(0)

    tp = Path(transcript_path)
    if not tp.exists():
        sys.exit(0)

    transcript_raw = tp.read_text(encoding="utf-8")

    if not is_de_relevant(transcript_raw):
        sys.exit(0)

    transcript = _parse_transcript(transcript_raw)
    session_text = extract_text(transcript)

    print("[extract_learnings] DE session detected — extracting learnings...", file=sys.stderr)

    analysis = analyze_with_claude(session_text)

    if not analysis.get("is_relevant", False):
        print("[extract_learnings] No new learnings found for this session.", file=sys.stderr)
        sys.exit(0)

    # Output directory: configurable via env var, default to ./docs/learnings/
    learnings_dir = Path(os.environ.get("LEARNINGS_DIR", "docs/learnings"))
    learnings_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M")
    output_path = learnings_dir / f"session_{timestamp}.md"

    render_summary(analysis, session_id, output_path)
    print(f"[extract_learnings] Summary written to: {output_path}", file=sys.stderr)
    sys.exit(0)


if __name__ == "__main__":
    main()
