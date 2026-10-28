#!/usr/bin/env python3
"""Analyse the newest DEBUG touch log pulled by scripts/touchlog.sh (build/touchlog/*.json).

Prints one line per touch (hold ms, drift pt, key index at down/up, moves) and flags the suspicious ones: drift over
8 pt, key changed between down and up, hold over 150 ms. Also checks every non-shift touch produced an insert. The log
never contains characters, only key indices and kinds. Usage: scripts/touchlog-analyze.py [file]"""
import glob, json, os, sys

path = sys.argv[1] if len(sys.argv) > 1 else max(glob.glob("build/touchlog/*.json"), key=os.path.getmtime)
d = json.load(open(path))
r = d["records"]
t0 = r[0]["ts"]
print(path, "records", len(r), "max lag ms %.0f" % max(x["lagMs"] for x in r), "longPressDelay", d.get("longPressDelay"))
kinds = {}
for x in r:
    kinds[x["type"]] = kinds.get(x["type"], 0) + 1
print(kinds)

touches = {}
for x in r:
    if x["type"] == "began":
        touches[x["id"]] = {"b": x, "mv": 0}
    elif x["type"] == "moved" and x["id"] in touches:
        touches[x["id"]]["mv"] += 1
    elif x["type"] == "ended" and x["id"] in touches:
        touches[x["id"]]["e"] = x

prev, flagged, typing = None, 0, 0
for k in sorted(touches):
    t = touches[k]
    b, e = t["b"], t.get("e")
    if not e:
        print("touch", k, "has no end event")
        continue
    hold = (e["ts"] - b["ts"]) * 1000
    gap = (b["ts"] - prev) * 1000 if prev else 0
    prev = b["ts"]
    drift = ((e["x"] - b["x"]) ** 2 + (e["y"] - b["y"]) ** 2) ** 0.5
    if b["kind"] != "other":
        typing += 1
    bad = b["ki"] != e["ki"] or drift > 8 or hold > 150
    flagged += bad
    print("%7.3f gap=%4.0f ki=%-3d %-6s hold=%4.0f drift=%4.0f moves=%d upKi=%d%s" % (
        b["ts"] - t0, gap, b["ki"], b["kind"], hold, drift, t["mv"], e["ki"], "   <--" if bad else ""))

inserts = sum(x["n"] for x in r if x["type"] == "insert")
print("touches %d (non-shift/other %d), inserts %d, flagged %d" % (len(touches), typing, inserts, flagged))
alt = [x for x in r if x["type"].startswith("alt")]
print("alternates events:", len(alt), "(any alternates during fast typing is a bug)" if alt else "")

# Hit-test records (DEBUG): which view class received each NEW touch. A hit that is not KeyGridView, or a hit with no
# matching "began", is a touch the key grid never saw.
hits = [x for x in r if x["type"] == "hit"]
if hits:
    classes = {}
    for h in hits:
        classes[h["kind"]] = classes.get(h["kind"], 0) + 1
    began = sum(1 for x in r if x["type"] == "began")
    print("hit-test receivers:", classes, "| began events:", began)
    for h in hits:
        if h["kind"] != "KeyGridView":
            print("  touch went to %s at (%.0f,%.0f) t=%.3f" % (h["kind"], h["x"], h["y"], h["ts"] - t0))
