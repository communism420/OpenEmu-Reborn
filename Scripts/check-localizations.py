#!/usr/bin/env python3
"""Read-only localization inventory. No network, generated translations or app launch.

Run --format json to obtain the canonical terms and missing translations. Errors
are mechanical failures; review findings require a person, not an English-copy
autofill. This is a source/resource check, not proof of linguistic or UI quality.
"""

import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


DEFAULT_SOURCES = ("OpenEmu", "OpenEmuKit", "OpenEmu-SDK")
# This existing regional resource contains InfoPlist overrides, not a separate
# full interface. Keep this explicit; never silently excuse any other locale.
REGIONAL_FALLBACKS = {"fr-CA": "fr"}
LOCALIZATION_CALLS = {
    "NSLocalizedString", "NSLocalizedStringFromTable",
    "NSLocalizedStringFromTableInBundle", "NSLocalizedStringWithDefaultValue",
}
UI_PROPERTIES = {
    "title", "messageText", "informativeText", "defaultButtonTitle",
    "alternateButtonTitle", "otherButtonTitle", "toolTip", "placeholderString",
    "label", "stringValue", "prompt", "message", "accessibilityLabel",
}


@dataclass(frozen=True)
class Token:
    kind: str
    value: str
    line: int


def decode_escapes(text, *, swift=False, openstep=False, hashes=0):
    """Decode string content without mangling literal UTF-8 text."""
    out = []
    dynamic = False
    prefix = "\\" + "#" * hashes
    i = 0
    while i < len(text):
        if not text.startswith(prefix, i):
            out.append(text[i])
            i += 1
            continue
        i += len(prefix)
        if i == len(text):
            raise ValueError("unfinished string escape")
        char = text[i]
        i += 1
        if swift and char == "(":
            dynamic = True
            out.append("\\(")
        elif char in "\\\"'":
            out.append(char)
        elif char in "nrtbfav0":
            out.append({"n": "\n", "r": "\r", "t": "\t", "b": "\b",
                        "f": "\f", "a": "\a", "v": "\v", "0": "\0"}[char])
        elif char in "\r\n":
            if char == "\r" and i < len(text) and text[i] == "\n":
                i += 1
        elif char == "u" and swift and i < len(text) and text[i] == "{":
            end = text.find("}", i)
            if end < 0:
                raise ValueError("unfinished Unicode escape")
            out.append(chr(int(text[i + 1:end], 16)))
            i = end + 1
        elif char in "uU":
            count = 4 if char == "u" or openstep else 8
            digits = text[i:i + count]
            if len(digits) != count or not re.fullmatch(r"[0-9a-fA-F]+", digits):
                raise ValueError("invalid Unicode escape")
            out.append(chr(int(digits, 16)))
            i += count
        elif char in "1234567":
            match = re.match(r"[0-7]{0,2}", text[i:])
            digits = char + match.group(0)
            out.append(chr(int(digits, 8)))
            i += len(digits) - 1
        elif char == "x" and not swift:
            match = re.match(r"[0-9a-fA-F]+", text[i:])
            if not match:
                raise ValueError("invalid hexadecimal escape")
            out.append(chr(int(match.group(0), 16)))
            i += len(match.group(0))
        else:
            raise ValueError("unsupported string escape: " + prefix + char)
    # OpenStep UTF-16 surrogate escapes must compare equal to literal Unicode.
    value = "".join(out).encode("utf-16", "surrogatepass").decode("utf-16")
    return value, dynamic


def tokenize(text, *, swift=False, openstep=False):
    """Small literal-aware lexer, including comments and Swift multiline strings.

    It intentionally does not evaluate expressions. Dynamic keys are reported
    for review instead of being mistaken for literal, fully covered strings.
    """
    result = []
    i = 0
    line = 1
    while i < len(text):
        if text[i].isspace():
            line += text[i] == "\n"
            i += 1
            continue
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
            continue
        if text.startswith("/*", i):
            depth, end = 1, i + 2
            while end < len(text) and depth:
                if text.startswith("/*", end):
                    depth += 1
                    end += 2
                elif text.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            if depth:
                raise ValueError(f"line {line}: unterminated comment")
            line += text[i:end].count("\n")
            i = end
            continue
        match = re.match(r'(@|#+)?("""|")', text[i:])
        if match:
            prefix, quote = match.group(1) or "", match.group(2)
            hashes = len(prefix) if prefix.startswith("#") else 0
            start = i + len(match.group(0))
            end = start
            close = quote + "#" * hashes
            while end < len(text):
                if text.startswith(close, end):
                    break
                if text.startswith("\\" + "#" * hashes, end):
                    end += hashes + 2
                else:
                    end += 1
            if end >= len(text):
                raise ValueError(f"line {line}: unterminated string")
            raw = text[start:end]
            if quote == '"""':
                if not raw.startswith("\n"):
                    raise ValueError(f"line {line}: multiline string has no opening newline")
                raw = raw[1:]
                lines = raw.split("\n")
                indent = lines.pop()
                if indent.strip():
                    raise ValueError(f"line {line}: invalid multiline closing indentation")
                if any(row.strip() and not row.startswith(indent) for row in lines):
                    raise ValueError(f"line {line}: invalid multiline indentation")
                raw = "\n".join(row[len(indent):] if row.startswith(indent) else row for row in lines)
            value, dynamic = decode_escapes(raw, swift=swift, openstep=openstep, hashes=hashes)
            result.append(Token("dynamic" if dynamic else "string", value, line))
            end += len(close)
            line += text[i:end].count("\n")
            i = end
            continue
        # Objective-C/C character literals may contain quote/comment characters.
        if not swift and text[i] == "'":
            end = i + 1
            while end < len(text) and text[end] != "'":
                end += 2 if text[end] == "\\" else 1
            if end >= len(text):
                raise ValueError(f"line {line}: unterminated character literal")
            result.append(Token("character", text[i:end + 1], line))
            line += text[i:end + 1].count("\n")
            i = end + 1
            continue
        match = re.match(r"[A-Za-z_][A-Za-z_0-9]*", text[i:])
        value = match.group(0) if match else text[i]
        result.append(Token("identifier" if match else "symbol", value, line))
        i += len(value)
    return result


def read_strings(path):
    """Load XML/binary or OpenStep .strings; detect duplicates before plist loss."""
    data = path.read_bytes()
    duplicates = []
    if data.startswith(b"bplist"):
        # Binary dictionaries cannot be usefully reviewed as translation source.
        raise ValueError("binary .strings is not supported as editable source; convert to XML")
    text = data.decode("utf-16" if data[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8-sig")
    if text.lstrip().startswith("<"):
        root = ET.fromstring(text)
        dictionary = root.find("dict") if root.tag == "plist" else None
        if dictionary is None:
            raise ValueError("expected a plist dictionary")
        keys = [element.text or "" for element in dictionary if element.tag == "key"]
        duplicates = sorted(key for key, count in Counter(keys).items() if count > 1)
        values = plistlib.loads(data)
    else:
        tokens = tokenize(text, openstep=True)
        keys = []
        cursor = 0
        while cursor < len(tokens):
            entry = tokens[cursor:cursor + 4]
            if (len(entry) != 4 or entry[0].kind != "string" or entry[1].value != "="
                    or entry[2].kind != "string" or entry[3].value != ";"):
                raise ValueError(f"line {tokens[cursor].line}: expected quoted key = quoted value;")
            keys.append(entry[0].value)
            cursor += 4
        duplicates = sorted(key for key, count in Counter(keys).items() if count > 1)
        # Apple's parser remains authoritative for OpenStep syntax/escapes.
        command = subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", "--", str(path)],
                                 check=False, capture_output=True)
        if command.returncode:
            raise ValueError("plutil rejected .strings: " + command.stderr.decode(errors="replace").strip())
        values = json.loads(command.stdout)
        if set(values) != set(keys):
            raise ValueError("literal parser and plutil disagree on dictionary keys")
    if not isinstance(values, dict) or any(not isinstance(k, str) or not isinstance(v, str)
                                          for k, v in values.items()):
        raise ValueError("all localization keys and values must be strings")
    return values, duplicates


def literal(tokens):
    if not tokens:
        return None
    # C/ObjC adjacent string literals and explicit literal + literal are static.
    if any(token.kind != "string" and token.value != "+" for token in tokens):
        return None
    if tokens[0].kind != "string" or tokens[-1].kind != "string":
        return None
    return "".join(token.value for token in tokens if token.kind == "string")


def call_arguments(tokens, opening):
    arguments, current, depth = [], [], 0
    for token in tokens[opening + 1:]:
        if token.kind == "symbol":
            if token.value in "([{":
                depth += 1
            elif token.value in ")]}":
                if depth == 0:
                    return arguments + [current]
                depth -= 1
            elif token.value == "," and depth == 0:
                arguments.append(current)
                current = []
                continue
        current.append(token)
    raise ValueError("unterminated localization call")


def control_source_references(tokens, path):
    """Inventory the SDK's literal producers consumed by ControlsSetupViewParser.

    These keys reach NSLocalizedString through controlPageList, not a literal
    localization call. Read the actual Button calls and section-array values;
    never infer translations from global-button identifiers or other metadata.
    The existing lexer excludes line/block comments before this scan.
    """
    references, reviews = [], []

    def add_key(key, token):
        if key is None:
            reviews.append({"kind": "dynamic_control_label", "path": path, "line": token.line,
                            "detail": "Control-list producer needs manual key inventory."})
        elif key:
            references.append({"key": key, "table": "ControlLabels", "path": path,
                               "line": token.line, "default": key})

    for i, token in enumerate(tokens):
        if token.kind != "identifier":
            continue
        if (token.value == "OE_globalButtonsControlList" and i + 1 < len(tokens)
                and tokens[i + 1].value == "{"):
            # Only the method definition, not a call, another method's Button
            # macro or the macro definition itself supplies global key labels.
            depth, end = 1, i + 2
            while end < len(tokens) and depth:
                current = tokens[end]
                if current.kind == "symbol":
                    depth += (current.value == "{") - (current.value == "}")
                end += 1
            if depth:
                raise ValueError("unterminated global-buttons control-list method")
            body = tokens[i + 2:end - 1]
            for j, current in enumerate(body[:-1]):
                if (current.kind == "identifier" and current.value == "Button"
                        and body[j + 1].value == "("
                        and not (j > 0 and body[j - 1].value == "define")):
                    arguments = call_arguments(body, j + 1)
                    add_key(literal(arguments[0]), current)
        if (token.value == "_controlPageList"
                and [item.value for item in tokens[i + 1:i + 4]] == ["=", "@", "["]):
            # Alternating section title / grouped controls, as consumed by
            # parseControlList. Only title slots are localization keys.
            arguments = call_arguments(tokens, i + 3)
            if arguments and not arguments[-1]:
                arguments.pop()  # Objective-C array literal's trailing comma.
            if len(arguments) % 2:
                raise ValueError("controlPageList must have section/content pairs")
            for title in arguments[::2]:
                add_key(literal(title), title[0] if title else token)
    return references, reviews


def control_plist_references(path, relative):
    """Read only the system plugin's OEControlListKey display schema.

    Group strings are displayed except the '-' separator; dictionary labels
    are displayed even when the label itself is '-'. Names, controller image
    positions and unrelated plist metadata are not localization keys.
    """
    values = plistlib.loads(path.read_bytes())
    if not isinstance(values, dict) or "OEControlListKey" not in values:
        return [], []
    groups = values["OEControlListKey"]
    if not isinstance(groups, list):
        raise ValueError("OEControlListKey must be an array of control groups")
    references = []
    for group_index, group in enumerate(groups):
        if not isinstance(group, list):
            raise ValueError("OEControlListKey must contain arrays of control rows")
        for row_index, row in enumerate(group):
            if isinstance(row, str):
                key = "" if row == "-" else row
            elif isinstance(row, dict):
                key = row.get("OEControlListKeyLabelKey", "")
                if not isinstance(key, str):
                    raise ValueError("OEControlListKeyLabelKey must be a string")
            else:
                raise ValueError("control row must be a group title or button dictionary")
            if key:
                references.append({"key": key, "table": "ControlLabels", "path": relative,
                                   "plist_key": f"OEControlListKey[{group_index}][{row_index}]",
                                   "default": key})
    return references, []


def source_references(text, path):
    tokens = tokenize(text, swift=path.endswith(".swift"))
    references, reviews = [], []
    for i, token in enumerate(tokens[:-1]):
        if token.kind == "identifier" and token.value in LOCALIZATION_CALLS and tokens[i + 1].value == "(":
            arguments = call_arguments(tokens, i + 1)
            key = literal(arguments[0])
            table = "Localizable"
            default = None
            if token.value != "NSLocalizedString":
                table = literal(arguments[1]) if len(arguments) > 1 else None
                if len(arguments) > 1 and len(arguments[1]) == 1 and arguments[1][0].value in {"nil", "NULL"}:
                    table = "Localizable"
                if token.value == "NSLocalizedStringWithDefaultValue" and len(arguments) > 3:
                    default = literal(arguments[3])
            for argument in arguments[1:]:
                if len(argument) > 2 and argument[1].value == ":":
                    if argument[0].value == "tableName":
                        table = "Localizable" if argument[2].value == "nil" else literal(argument[2:])
                    elif argument[0].value == "value":
                        default = literal(argument[2:])
            if key is None or table is None:
                reviews.append({"kind": "dynamic_key", "path": path, "line": token.line,
                                "detail": "Localization key or table needs manual inventory."})
            elif key:
                references.append({"key": key, "table": table, "path": path, "line": token.line,
                                   "default": default or key})
        # Deliberately a review heuristic, not a claim to find all user-visible text.
        if (token.kind == "identifier" and token.value in UI_PROPERTIES and i + 2 < len(tokens)
                and tokens[i + 1].value in {"=", ":"} and tokens[i + 2].kind in {"string", "dynamic"}
                and tokens[i + 2].value.strip()):
            reviews.append({"kind": "hardcoded_ui", "path": path, "line": token.line,
                            "key": tokens[i + 2].value, "detail": "Literal UI property; review its localization path."})
    if path.endswith((".m", ".mm")):
        control_references, control_reviews = control_source_references(tokens, path)
        references.extend(control_references)
        reviews.extend(control_reviews)
    return references, reviews


def xib_references(path, relative, english):
    root = ET.parse(path).getroot()
    parents = {child: parent for parent in root.iter() for child in parent}
    references, reviews = [], []
    for element in root.iter():
        attribute = element.find("./userDefinedRuntimeAttributes/userDefinedRuntimeAttribute[@keyPath='localizeTitle']")
        if attribute is None or attribute.get("value") != "YES":
            owner = parents.get(element) if element.tag.endswith("Cell") else element
            owner_attribute = owner.find("./userDefinedRuntimeAttributes/userDefinedRuntimeAttribute[@keyPath='localizeTitle']") if owner is not None else None
            if (element.tag in {"buttonCell", "textFieldCell", "menu", "menuItem", "tableColumn"}
                    and element.get("title", "").strip()
                    and (owner_attribute is None or owner_attribute.get("value") != "YES")):
                reviews.append({"kind": "hardcoded_xib_title", "path": relative, "key": element.get("title"),
                                "detail": "Review title without localizeTitle: " + (element.get("id") or element.tag)})
            continue
        table = "MainMenu" if element.tag in {"menu", "menuItem"} else "OEControls"
        targets = [element] + [child for child in element if child.tag.endswith("Cell")]
        key = next((target.get("title") for target in targets if target.get("title") is not None), None)
        if key is None:
            key = next((child.text for target in targets for child in target
                        if child.tag == "string" and child.get("key") in {"title", "stringValue"}), None)
        if not key:
            reviews.append({"kind": "dynamic_xib_title", "path": relative,
                            "detail": "localizeTitle has no static title: " + (element.get("id") or element.tag)})
            continue
        if table == "MainMenu" and key not in english.get(table, {}) and key in english.get("Localizable", {}):
            table = "Localizable"  # NSControl+i18n.swift's explicit menu fallback.
        references.append({"key": key, "table": table, "path": relative,
                           "object_id": element.get("id", ""), "default": key})
    return references, reviews


FORMAT = re.compile(r"%(?:(?P<position>[1-9][0-9]*)\$)?[-+ #0']*"
                    r"(?:(?P<width>\*)(?:(?P<width_position>[1-9][0-9]*)\$)?|[0-9]+)?"
                    r"(?:\.(?:(?P<precision>\*)(?:(?P<precision_position>[1-9][0-9]*)\$)?|[0-9]*))?"
                    r"(?P<length>hh|ll|[hlqLztj])?(?P<conversion>[@diuoxXfFeEgGaAcCsSpn%])")


def format_signature(value):
    """Compare argument positions/types, accepting %2$@ reordering and %% escapes."""
    arguments = Counter()
    implicit = 1
    explicit_used = implicit_used = False
    for match in FORMAT.finditer(value):
        parts = match.groupdict()
        if parts["conversion"] == "%":
            continue
        length = parts["length"] or ""
        conversion = parts["conversion"]
        if conversion in "di":
            kind = length + "signed"
        elif conversion in "uoxX":
            kind = length + "unsigned"
        elif conversion in "fFeEgGaA":
            kind = "long-double" if length == "L" else "double"
        else:
            kind = length + conversion
        consumers = []
        for field in ("width", "precision"):
            if parts[field]:
                consumers.append((parts[field + "_position"], "signed"))
        consumers.append((parts["position"], kind))
        for position, argument_kind in consumers:
            if position:
                explicit_used = True
                index = int(position)
            else:
                implicit_used = True
                index = implicit
                implicit += 1
            arguments[(index, argument_kind)] += 1
    if explicit_used and implicit_used:
        raise ValueError("mixed positional and non-positional format arguments")
    return [[index, kind, count] for (index, kind), count in sorted(arguments.items())]


def finding(kind, severity, **fields):
    value = {"kind": kind, "severity": severity, **fields}
    identity = {key: value[key] for key in ("kind", "locale", "table", "key", "path", "line", "detail") if key in value}
    value["id"] = hashlib.sha256(json.dumps(identity, ensure_ascii=True, sort_keys=True).encode()).hexdigest()[:20]
    return value


def audit(repository, app_root="OpenEmu", source_roots=DEFAULT_SOURCES, locales=None, policy=None):
    repository = Path(repository).resolve()
    app = repository / app_root
    dictionaries = defaultdict(dict)
    findings = []
    language_dirs = sorted(path for path in app.glob("*.lproj") if path.name != "Base.lproj")
    discovered = [path.stem for path in language_dirs]
    selected_set = set(locales or discovered) | {"en"}
    selected_set.update(REGIONAL_FALLBACKS[locale] for locale in tuple(selected_set) if locale in REGIONAL_FALLBACKS)
    selected = sorted(selected_set)
    for locale in selected:
        if locale not in discovered:
            findings.append(finding("missing_locale", "error", locale=locale))
    for directory in language_dirs:
        if directory.stem not in selected:
            continue
        for path in sorted(directory.glob("*.strings")):
            relative = path.relative_to(repository).as_posix()
            try:
                values, duplicates = read_strings(path)
                dictionaries[directory.stem][path.stem] = values
                for key in duplicates:
                    findings.append(finding("duplicate_key", "error", locale=directory.stem,
                                            table=path.stem, key=key, path=relative))
            except (ValueError, OSError, ET.ParseError, plistlib.InvalidFileException) as error:
                findings.append(finding("invalid_strings", "error", locale=directory.stem,
                                        table=path.stem, path=relative, detail=str(error)))
    english = dictionaries["en"]
    if not english:
        findings.append(finding("missing_english_tables", "error", locale="en", path=app_root))
    references = []
    paths = set()
    for source_root in source_roots:
        root = repository / source_root
        if not root.is_dir():
            continue
        for path in root.rglob("*"):
            is_system_plist = path.suffix == ".plist" and "SystemPlugins" in path.relative_to(repository).parts
            if (path.suffix in {".swift", ".m", ".mm", ".xib"} or is_system_plist) and not any(
                    component in {"Tests", "OpenEmuTests", "OEAlertTest", "Build", "build", ".git"}
                    for component in path.relative_to(root).parts):
                paths.add(path)
    for path in sorted(paths):
        relative = path.relative_to(repository).as_posix()
        try:
            if path.suffix == ".xib":
                new_references, reviews = xib_references(path, relative, english)
            elif path.suffix == ".plist":
                new_references, reviews = control_plist_references(path, relative)
            else:
                new_references, reviews = source_references(path.read_text(encoding="utf-8-sig"), relative)
            references.extend(new_references)
            findings.extend(finding(review.pop("kind"), "review", **review) for review in reviews)
        except (ValueError, OSError, ET.ParseError, plistlib.InvalidFileException) as error:
            findings.append(finding("unscanned_source", "error", path=relative, detail=str(error)))
    by_term = defaultdict(list)
    defaults = {}
    for reference in references:
        key = reference["table"], reference["key"]
        defaults.setdefault(key, reference["default"])
        by_term[key].append({name: value for name, value in reference.items() if name not in {"key", "table", "default"}})
    terms = set(by_term)
    terms.update((table, key) for table, values in english.items() for key in values)
    canonical = []
    for table, key in sorted(terms):
        source = english.get(table, {}).get(key, defaults.get((table, key), key))
        try:
            expected = format_signature(source)
        except ValueError as error:
            expected = None
            findings.append(finding("invalid_format", "error", locale="en", table=table, key=key, detail=str(error)))
        missing = []
        inherited = {}
        for locale in selected:
            values = dictionaries[locale].get(table, {})
            fallback = REGIONAL_FALLBACKS.get(locale)
            if key not in values and fallback and key in dictionaries[fallback].get(table, {}):
                # The base-language term is checked independently below. This
                # region deliberately inherits it; don't generate duplicate work.
                inherited[locale] = fallback
                continue
            path = f"{app_root}/{locale}.lproj/{table}.strings"
            if key not in values:
                missing.append(locale)
                findings.append(finding("missing_key", "error", locale=locale, table=table, key=key, path=path))
                continue
            translated = values[key]
            if not translated.strip():
                findings.append(finding("empty_translation", "error", locale=locale, table=table, key=key, path=path))
            try:
                actual = format_signature(translated)
                if expected is not None and actual != expected:
                    findings.append(finding("placeholder_mismatch", "error", locale=locale, table=table, key=key,
                                            path=path, expected=expected, actual=actual))
            except ValueError as error:
                findings.append(finding("invalid_format", "error", locale=locale, table=table, key=key,
                                        path=path, detail=str(error)))
            if locale != "en" and translated == source and translated.strip():
                findings.append(finding("identical_to_english", "review", locale=locale, table=table, key=key,
                                        path=path, detail="May be a proper name, symbol or valid shared word; review before changing."))
        canonical.append({"table": table, "key": key, "english": source,
                          "references": sorted(by_term[(table, key)], key=lambda value: json.dumps(value, sort_keys=True)),
                          "missing_locales": missing, "inherited_locales": inherited})
    # Locale-only entries remain visible for review, never silently discarded.
    for locale in selected:
        for table, values in dictionaries[locale].items():
            for key in sorted(values):
                if (table, key) not in terms:
                    findings.append(finding("locale_only_key", "review", locale=locale, table=table, key=key))
    accepted = (policy or {}).get("accepted", [])
    accepted_ids = {}
    for item in accepted:
        if (not isinstance(item, dict) or not isinstance(item.get("id"), str)
                or not isinstance(item.get("reason"), str) or not item["reason"].strip()):
            raise ValueError("each accepted finding requires an exact id and nonempty reason")
        if item["id"] in accepted_ids:
            raise ValueError("duplicate policy id: " + item["id"])
        accepted_ids[item["id"]] = item["reason"]
    present_ids = set()
    for item in findings:
        present_ids.add(item["id"])
        if item["id"] in accepted_ids:
            if item["severity"] != "review":
                raise ValueError("policy cannot suppress a mechanical error: " + item["id"])
            item["accepted_reason"] = accepted_ids[item["id"]]
    for stale in sorted(set(accepted_ids) - present_ids):
        findings.append(finding("stale_policy_entry", "error", key=stale,
                                detail="Remove or re-review this no-longer-matching allowance."))
    findings.sort(key=lambda value: (value["severity"], value["kind"], value.get("locale", ""),
                                     value.get("table", ""), value.get("key", ""),
                                     value.get("path", ""), value.get("line", 0)))
    counts = Counter(item["kind"] for item in findings)
    return {"schema_version": 1, "locales": selected, "regional_fallbacks": REGIONAL_FALLBACKS,
            "canonical_terms": canonical,
            "summary": {"terms": len(canonical), "source_files": len(paths), "counts": dict(sorted(counts.items())),
                        "errors": sum(item["severity"] == "error" for item in findings),
                        "unreviewed": sum(item["severity"] == "review" and "accepted_reason" not in item for item in findings)},
            "findings": findings}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--app-root", default="OpenEmu", help="relative localization resources directory")
    parser.add_argument("--source-root", action="append", help="relative source directory; repeat as needed")
    parser.add_argument("--locale", action="append", help="check only these locales plus English; default: every .lproj")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument("--policy", type=Path, help="JSON accepted review findings with exact id and reason")
    parser.add_argument("--require-reviewed", action="store_true", help="also fail on unreviewed findings")
    arguments = parser.parse_args()
    try:
        policy = json.loads(arguments.policy.read_text()) if arguments.policy else None
        result = audit(arguments.repo, arguments.app_root, arguments.source_root or DEFAULT_SOURCES,
                       arguments.locale, policy)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    if arguments.format == "json":
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print("Locales: " + ", ".join(result["locales"]))
        print(f"Canonical terms: {result['summary']['terms']}; source files: {result['summary']['source_files']}")
        for kind, count in result["summary"]["counts"].items():
            print(f"  {kind}: {count}")
        print(f"Errors: {result['summary']['errors']}; unreviewed findings: {result['summary']['unreviewed']}")
        print("Use --format json for every finding, exact review IDs and canonical translation terms.")
        print("Identical text is review-only. This audit does not prove translation or layout quality.")
    return 1 if result["summary"]["errors"] or (arguments.require_reviewed and result["summary"]["unreviewed"]) else 0


if __name__ == "__main__":
    sys.exit(main())
