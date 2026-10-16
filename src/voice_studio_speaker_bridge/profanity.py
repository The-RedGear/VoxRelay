"""Opt-in, whole-word profanity rules. Replacements never cascade."""
from __future__ import annotations

import random
import re
import json
import sys
from pathlib import Path


def default_rules() -> list[dict]:
    root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[2]))
    families = json.loads((root / "assets" / "profanity-defaults.json").read_text(encoding="utf-8"))
    return [{"word": word, "variants": forms, "enabled": True,
             "match_variants": True, "action": "replace", "replacement": "bleep"}
            for word, forms in families.items()]


def normalize_rules(value: object) -> list[dict]:
    if not isinstance(value, list):
        return default_rules()
    result = []
    seen = set()
    for rule in value[:500]:
        if not isinstance(rule, dict):
            continue
        word = str(rule.get("word", "")).strip()[:120]
        if not word or word.casefold() in seen:
            continue
        seen.add(word.casefold())
        forms = rule.get("variants", [])
        if isinstance(forms, str):
            forms = forms.split(",")
        if not isinstance(forms, list):
            forms = []
        result.append({"word": word, "variants": [str(f).strip()[:120] for f in forms[:100] if str(f).strip()],
                       "enabled": bool(rule.get("enabled", True)),
                       "match_variants": bool(rule.get("match_variants", True)),
                       "action": rule.get("action") if rule.get("action") in ("replace", "remove", "block") else "replace",
                       "replacement": str(rule.get("replacement", "bleep"))[:1000]})
    return result


def _edits(text: str, rules: list[dict]) -> list[tuple[int, int, str]]:
    terms = {}
    for rule in rules:
        if not rule.get("enabled", True):
            continue
        forms = [rule["word"]] + (rule.get("variants", []) if rule.get("match_variants", True) else [])
        for form in forms:
            terms.setdefault(form.casefold(), rule)
    if not terms:
        return []
    named = {f"t{i}": (term, terms[term]) for i, term in enumerate(sorted(terms, key=len, reverse=True))}
    pattern = re.compile(r"(?<!\w)(?:" + "|".join(f"(?P<{name}>{re.escape(term)})" for name, (term, _) in named.items()) + r")(?!\w)", re.I)
    if any(named[m.lastgroup][1]["action"] == "block" for m in pattern.finditer(text)):
        raise ValueError("Message blocked by the profanity filter")

    def replace(match):
        rule = named[match.lastgroup][1]
        if rule["action"] == "remove":
            return ""
        choices = [s.strip() for s in rule.get("replacement", "").split(",") if s.strip()]
        return random.choice(choices) if choices else ""

    return [(m.start(), m.end(), replace(m)) for m in pattern.finditer(text)]


def filter_text(text: str, rules: list[dict]) -> str:
    for start, end, replacement in reversed(_edits(text, rules)):
        text = text[:start] + replacement + text[end:]
    return re.sub(r"\s+", " ", text).strip()


def filter_ssml(root, rules: list[dict]) -> None:
    """Match across markup boundaries while preserving the SSML structure."""
    slots = []
    position = 0

    def add(node, attribute):
        nonlocal position
        value = getattr(node, attribute) or ""
        slots.append((node, attribute, value, position))
        position += len(value)

    def visit(node):
        add(node, "text")
        for child in node:
            visit(child)
            add(child, "tail")

    visit(root)
    changes = _edits("".join(s[2] for s in slots), rules)
    for node, attribute, value, offset in slots:
        for start, end, replacement in reversed(changes):
            left, right = max(start, offset), min(end, offset + len(value))
            if left < right:
                value = value[:left-offset] + (replacement if left == start else "") + value[right-offset:]
        setattr(node, attribute, value)
    for node in root.iter():
        if node.tag.rsplit("}", 1)[-1] == "sub" and "alias" in node.attrib:
            node.attrib["alias"] = filter_text(node.attrib["alias"], rules)
