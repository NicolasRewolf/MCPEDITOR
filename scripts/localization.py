#!/usr/bin/env python3
"""Keep the string catalog exact: every text the app shows has its English version, and nothing else.

French is the source language. The compiler lists the strings each source file uses
(swiftc -emit-localized-strings); this check compares them with Localization/Localizable.xcstrings.

    python3 scripts/localization.py check Localization/Localizable.xcstrings .build/localized-strings

A missing key, a missing English text, an unused key or a format specifier that differs from
its French source fails the check, so a release never shows a French string in English or the
other way round.
"""
import json
import re
import sys
from pathlib import Path

SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l)?[@dDuUxXoOfFeEgGcCsSpaA]")


def used_keys(strings_dir):
    keys = set()
    for path in Path(strings_dir).glob("*.stringsdata"):
        data = json.loads(path.read_text())
        # A deleted source leaves its last listing behind; it no longer counts.
        if not Path(data["source"]).exists():
            continue
        keys.update(entry["key"] for entry in data["tables"].get("Localizable", []))
    return keys


def texts(localization):
    if "stringUnit" in localization:
        return [localization["stringUnit"]["value"]]
    return [form["stringUnit"]["value"] for form in localization["variations"]["plural"].values()]


def specifiers(text):
    return sorted(SPECIFIER.findall(text.replace("%%", "")))


def check(catalog_path, strings_dir):
    entries = json.loads(Path(catalog_path).read_text())["strings"]
    used = used_keys(strings_dir)
    if not used:
        sys.exit(f"Aucun texte relevé dans {strings_dir} : compiler avec -emit-localized-strings.")
    problems = [f"absent du catalogue : {key!r}" for key in sorted(used - set(entries))]
    problems += [f"inutilisé : {key!r}" for key in sorted(set(entries) - used)]
    for key in sorted(used & set(entries)):
        localizations = entries[key].get("localizations", {})
        if "en" not in localizations:
            problems.append(f"sans anglais : {key!r}")
        for language, localization in localizations.items():
            for text in texts(localization):
                if specifiers(text) != specifiers(key):
                    problems.append(f"formats différents ({language}) : {key!r} → {text!r}")
    if problems:
        sys.exit("\n".join(problems))
    print(f"LOCALIZATION_OK: {len(used)} textes en français et en anglais")


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] != "check":
        sys.exit(__doc__)
    check(sys.argv[2], sys.argv[3])
