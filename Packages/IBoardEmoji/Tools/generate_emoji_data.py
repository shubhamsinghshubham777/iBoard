#!/usr/bin/env python3
"""Deterministic generator for Sources/IBoardEmoji/Resources/emoji.json.

Inputs (Unicode License v3 data, see docs/EMOJI_DATA.md):
  --src DIR   a directory holding
                emoji-test.txt
                a/en/annotations.json   (cldr-annotations-full)
                a/hi/annotations.json
                d/en/annotations.json   (cldr-annotations-derived-full)
                d/hi/annotations.json
  --overlay   Tools/hinglish_overlay.json (project-authored, Apache-2.0)
  --out       output json (default: ../Sources/IBoardEmoji/Resources/emoji.json)

Output format (compact, array rows to stay small):
  {"format":1,"source":"...","groups":[name...],
   "e":[[emoji, groupIndex, name, enKeywords, hiKeywords, tones, hinglish], ...]}
  keywords are "|"-joined lowercase strings; tones is the 5 uniform skin-tone
  variants joined by "|" (light..dark) or "".
Run: python3 -I generate_emoji_data.py --src <dir>
"""
import argparse, json, os, re, sys

MODS = set(range(0x1F3FB, 0x1F400))
FE0F = "️"


def strip_fe0f(s):
    return s.replace(FE0F, "")


def parse_emoji_test(path):
    group = None
    version = ""
    entries = []  # (group, cps tuple, emoji string, name)
    pat = re.compile(r"^([0-9A-F ]+?)\s*;\s*([\w-]+)\s*#\s*(\S+)\s+E[\d.]+\s+(.*)$")
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            continue
        if line.startswith("# Version:"):
            version = line.split(":", 1)[1].strip()
        if not line or line.startswith("#"):
            continue
        m = pat.match(line)
        if not m:
            raise SystemExit("unparsed line: " + line)
        cps = tuple(int(x, 16) for x in m.group(1).split())
        if m.group(2) != "fully-qualified" or group == "Component":
            continue
        entries.append((group, cps, m.group(3), m.group(4)))
    return version, entries


def load_ann(src, kind, lang):
    d = json.load(open(os.path.join(src, kind, lang, "annotations.json"), encoding="utf-8"))
    root = d["annotations"] if kind == "a" else d["annotationsDerived"]
    return root["annotations"]


def keywords(anns, emoji):
    for key in (emoji, strip_fe0f(emoji), strip_fe0f(emoji) + FE0F):
        for table in anns:
            a = table.get(key)
            if a:
                out = []
                for w in a.get("default", []) + a.get("tts", []):
                    w = w.lower().strip()
                    if w and w not in out:
                        out.append(w)
                return out
    return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--overlay", default=os.path.join(here, "hinglish_overlay.json"))
    ap.add_argument("--out", default=os.path.join(here, "..", "Sources", "IBoardEmoji", "Resources", "emoji.json"))
    a = ap.parse_args()

    version, entries = parse_emoji_test(os.path.join(a.src, "emoji-test.txt"))
    en = [load_ann(a.src, "a", "en"), load_ann(a.src, "d", "en")]
    hi = [load_ann(a.src, "a", "hi"), load_ann(a.src, "d", "hi")]
    overlay = json.load(open(a.overlay, encoding="utf-8"))
    overlay = {strip_fe0f(k): v.lower() for k, v in overlay.items() if not k.startswith("_")}

    groups = []
    base = []  # [group, emoji, name, key]
    tones = {}  # key -> {modifier: emoji}
    for group, cps, emoji, name in entries:
        mods = [c for c in cps if c in MODS]
        if not mods:
            if group not in groups:
                groups.append(group)
            base.append([group, emoji, name, strip_fe0f(emoji)])
        else:
            if len(set(mods)) != 1:
                continue
            key = strip_fe0f("".join(chr(c) for c in cps if c not in MODS))
            tones.setdefault(key, {})[mods[0]] = emoji

    rows = []
    used_overlay = set()
    for group, emoji, name, key in base:
        t = tones.get(key, {})
        tone_str = "|".join(t[m] for m in sorted(t)) if len(t) == 5 else ""
        h = overlay.get(key, "")
        if h:
            used_overlay.add(key)
        rows.append([emoji, groups.index(group), name,
                     "|".join(keywords(en, emoji)), "|".join(keywords(hi, emoji)),
                     tone_str, h])
    missing = sorted(set(overlay) - used_overlay)
    if missing:
        print("WARNING overlay keys not in data: " + " ".join(missing), file=sys.stderr)

    out = {"format": 1, "source": "Unicode emoji-test.txt " + version + "; CLDR annotations en+hi (Unicode License v3)",
           "groups": groups, "e": rows}
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")
    print("emoji:", len(rows), "with tones:", sum(1 for r in rows if r[5]), "bytes:", os.path.getsize(a.out))


if __name__ == "__main__":
    main()
