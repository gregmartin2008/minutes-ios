#!/usr/bin/env python3
"""Scores minutes-bench output against a reference: who-spoke-when error, word error, and
speaker-attributed word error. Self-contained (no third-party packages).

usage: score_meeting.py result.json meeting.ref.json [--max-der 0.25] [--max-wer 0.15] [--max-cpwer 0.30] [--json out.json]
"""
import itertools, json, re, sys

def norm_words(text):
    text = text.lower().replace("-", " ")
    text = re.sub(r"[^a-z0-9' ]+", " ", text)
    return [w.strip("'") for w in text.split() if w.strip("'")]

def edit_distance(ref, hyp):
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1]

def frames(segments, step, total):
    n = int(total / step) + 1
    grid = [set() for _ in range(n)]
    for s in segments:
        a, b = int(round(s["start"] / step)), int(round(s["end"] / step))
        for t in range(max(0, a), min(n, b)):
            grid[t].add(s["speaker"])
    return grid

def best_mapping(ref_labels, hyp_labels, weight):
    """One-to-one hyp->ref assignment maximizing total weight. Exhaustive, fine for a handful of speakers."""
    hyp_labels = list(hyp_labels)
    ref_labels = list(ref_labels) + [None] * max(0, len(hyp_labels) - len(ref_labels))
    best, best_total = {}, -1
    for perm in itertools.permutations(ref_labels, len(hyp_labels)):
        total = sum(weight.get((h, r), 0) for h, r in zip(hyp_labels, perm) if r is not None)
        if total > best_total:
            best_total, best = total, {h: r for h, r in zip(hyp_labels, perm) if r is not None}
    return best

def der(ref, hyp, step=0.01):
    total = max([s["end"] for s in ref] + [s["end"] for s in hyp] + [0])
    rg, hg = frames(ref, step, total), frames(hyp, step, total)
    weight = {}
    for r, h in zip(rg, hg):
        for a in h:
            for b in r:
                weight[(a, b)] = weight.get((a, b), 0) + 1
    mapping = best_mapping({s["speaker"] for s in ref}, {s["speaker"] for s in hyp}, weight)
    miss = fa = conf = ref_total = 0
    for r, h in zip(rg, hg):
        nr, nh = len(r), len(h)
        ref_total += nr
        correct = len({mapping.get(x) for x in h} & r)
        miss += max(0, nr - nh); fa += max(0, nh - nr); conf += min(nr, nh) - correct
    return {"der": (miss + fa + conf) / max(ref_total, 1), "miss": miss / max(ref_total, 1),
            "false_alarm": fa / max(ref_total, 1), "confusion": conf / max(ref_total, 1), "mapping": mapping}

def main():
    args = sys.argv[1:]
    result = json.load(open(args[0])); ref = json.load(open(args[1]))["lines"]
    limits = {"--max-der": None, "--max-wer": None, "--max-cpwer": None}
    out_json = None
    i = 2
    while i < len(args):
        if args[i] in limits: limits[args[i]] = float(args[i + 1])
        elif args[i] == "--json": out_json = args[i + 1]
        i += 2

    d = der(ref, result["turns"])
    ref_words = [w for line in sorted(ref, key=lambda r: r["start"]) for w in norm_words(line["text"])]
    hyp_words = [w for word in result["words"] for w in norm_words(word["text"])]
    wer = edit_distance(ref_words, hyp_words) / max(len(ref_words), 1)

    # Speaker-attributed error: concatenate each speaker's words, map hypothesis speakers to reference
    # speakers the way that minimizes total errors, and count every word given to the wrong person.
    ref_by, hyp_by = {}, {}
    for line in sorted(ref, key=lambda r: r["start"]):
        ref_by.setdefault(line["speaker"], []).extend(norm_words(line["text"]))
    for u in result["utterances"]:
        hyp_by.setdefault(u["speaker"], []).extend(norm_words(u["text"]))
    cost = {(h, r): edit_distance(ref_by[r], hyp_by[h]) for h in hyp_by for r in ref_by}
    gain = {(h, r): len(ref_by[r]) + len(hyp_by[h]) - cost[(h, r)] for h in hyp_by for r in ref_by}
    mapping = best_mapping(ref_by.keys(), hyp_by.keys(), gain)
    errors = sum(cost[(h, r)] for h, r in mapping.items())
    errors += sum(len(ref_by[r]) for r in ref_by if r not in mapping.values())
    errors += sum(len(hyp_by[h]) for h in hyp_by if h not in mapping)
    cpwer = errors / max(len(ref_words), 1)

    crosstalk_flagged = sum(1 for u in result["utterances"] if u.get("overlapWith"))
    summary = {
        "audio_seconds": round(result["audioSeconds"], 1), "reference_speakers": len(ref_by),
        "found_speakers": result["speakers"], "der": round(d["der"], 4), "miss": round(d["miss"], 4),
        "false_alarm": round(d["false_alarm"], 4), "confusion": round(d["confusion"], 4),
        "wer": round(wer, 4), "cpwer": round(cpwer, 4), "reference_words": len(ref_words),
        "utterances": len(result["utterances"]), "utterances_marked_crosstalk": crosstalk_flagged,
        "crosstalk_seconds_found": round(result["crosstalkSeconds"], 1),
        "separation_speed_x": round(result["audioSeconds"] / max(result["separationSeconds"], 1e-3), 1),
        "transcription_speed_x": round(result["audioSeconds"] / max(result["transcriptionSeconds"], 1e-3), 1),
    }
    print(json.dumps(summary, indent=1))
    if out_json: json.dump(summary, open(out_json, "w"), indent=1)

    failures = []
    for flag, key in (("--max-der", "der"), ("--max-wer", "wer"), ("--max-cpwer", "cpwer")):
        if limits[flag] is not None and summary[key] > limits[flag]:
            failures.append(f"{key} {summary[key]:.3f} exceeds {limits[flag]}")
    if failures:
        sys.exit("FAIL: " + "; ".join(failures))

if __name__ == "__main__":
    main()
