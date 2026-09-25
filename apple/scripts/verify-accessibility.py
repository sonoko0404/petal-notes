#!/usr/bin/env python3
"""Bounded static control audit. Complements (never replaces) AX/VoiceOver runtime tests."""
import json
from pathlib import Path
import re

def control_errors(source):
    errors = []
    for modifier in ["accessibilityLabel", "accessibilityValue", "contentShape"]:
        if "." + modifier + "(" not in source: errors.append("missing " + modifier)
    dimensions = re.findall(r"(?:minWidth|width|minHeight|height):\s*(\d+)", " ".join(re.findall(r"\.frame\(([^)]+)\)", source)))
    if len(dimensions) < 2 or min(map(int, dimensions)) < 28: errors.append("target below 28pt")
    return errors

def verify(root):
    errors = []
    contracts = [
        ("PetalChecklist/CardLibrary/CardLibraryView.swift", "Button(action: onCreate)", '.accessibilityIdentifier("card.create")'),
        ("PetalChecklist/CardEditor/CardLineRow.swift", "if line.kind == .todo {", '.accessibilityIdentifier(effectiveCompleted'),
        ("PetalChecklist/CardEditor/CardLineRow.swift", "Menu {", '.accessibilityIdentifier(line.kind == .todo ? "line.kind.todo"'),
        ("PetalWidgets/ChecklistWidgetView.swift", "Button(intent: OpenCardIntent", ".disabled(entry.snapshot.cardState =="),
        ("PetalWidgets/ChecklistWidgetView.swift", "Button(intent: QuickAddIntent", ".disabled(entry.snapshot.cardState !=")]
    for path, start, end in contracts:
        source = (root / path).read_text()
        if start not in source or end not in source: errors.append(path + ": missing control contract"); continue
        body = source.split(start, 1)[1].split(end, 1)[0]
        errors += [path + ": " + issue for issue in control_errors(body)]
    widget = (root / "PetalWidgets/ChecklistWidgetView.swift").read_text()
    # Fixed Widget rows use their full remaining slot, not an impossible 44pt vertical requirement.
    for start, end in [("case .todo(let intent):", "case .link(let url):"), ("case .link(let url):", "private func rowLabel")]:
        body = widget.split(start, 1)[1].split(end, 1)[0]
        for modifier in ["accessibilityLabel", "accessibilityValue", "accessibilityHint"]:
            if "." + modifier + "(" not in body: errors.append("Widget row missing " + modifier)
    for requirement in [".contentShape(Rectangle())", "minHeight: height", "accessibilityReduceTransparency", "contrast == .increased"]:
        if requirement not in widget: errors.append("Widget missing " + requirement)
    for base in [root / "PetalChecklist", root / "PetalWidgets"]:
        for file in base.rglob("*.swift"):
            source = file.read_text()
            if re.search(r"withAnimation\s*\(|\.animation\s*\(|\.transition\s*\(", source) and "accessibilityReduceMotion" not in source:
                errors.append(str(file) + ": custom animation lacks Reduce Motion handling")
    return errors

if __name__ == "__main__":
    errors = verify(Path(__file__).resolve().parents[1])
    print(json.dumps({"static_accessibility": "FAIL" if errors else "PASS", "errors": errors,
        "scope": "five icon controls; Widget todo/text rows; full-slot hit regions; custom motion and material policies; live AX remains separate"}, indent=2))
    raise SystemExit(bool(errors))
