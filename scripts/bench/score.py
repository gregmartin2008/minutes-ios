#!/usr/bin/env python3
"""Scores minutes-bench results against reference transcripts with the field's standard tools.

Measures, per meeting and pooled over all meetings:
  DER      who-spoke-when error (pyannote.metrics), with the customary 0.25 s collar and with none;
           overlapping speech is always scored.
  speakers how many voices were found against how many people spoke.
  tcORC    word error ignoring who spoke (MeetEval tcORC-WER, 5 s collar): the transcript's wording.
  tcpWER   word error counting a word given to the wrong person as wrong (MeetEval tcpWER, 5 s
           collar): the transcript as a whole. This is the NOTSOFAR-1 / CHiME-8 ranking metric.
Text is normalized with Whisper's English normalizer before comparison, as those challenges do.

usage: score.py DIR [DIR...] [--variants main,max,...] [--json out.json] [--per-meeting]
Each DIR holds <meeting>.result.json and <meeting>.ref.json files.
Requires: pip install meeteval pyannote.metrics whisper-normalizer
"""
import argparse, collections, glob, json, os, sys, warnings

warnings.filterwarnings("ignore")
import meeteval
from meeteval.io.seglst import SegLST
from pyannote.core import Annotation, Segment
from pyannote.metrics.diarization import DiarizationErrorRate
from whisper_normalizer.english import EnglishTextNormalizer

normalize = EnglishTextNormalizer()


def load(dirs):
    meetings = {}
    for d in dirs:
        for path in sorted(glob.glob(os.path.join(d, "**", "*.result.json"), recursive=True)):
            name = os.path.basename(path)[: -len(".result.json")]
            ref_path = path[: -len(".result.json")] + ".ref.json"
            if os.path.exists(ref_path):
                meetings[name] = (json.load(open(path)), json.load(open(ref_path)))
    return meetings


def annotation(segments):
    a = Annotation()
    for i, s in enumerate(segments):
        if s["end"] > s["start"]:
            a[Segment(s["start"], s["end"]), i] = s["speaker"]
    return a


def seglst(session, segments):
    rows = []
    for s in segments:
        words = normalize(s["text"])
        if words.strip():
            rows.append({
                "session_id": session, "speaker": s["speaker"], "start_time": float(s["start"]),
                "end_time": float(max(s["end"], s["start"] + 0.01)), "words": words,
            })
    return SegLST.new(rows)


def timed_pieces(utterances, words, size=8):
    """Splits each utterance into short pieces carrying the recognizer's own word times, so that
    time-constrained scoring does not have to guess where words fall inside a long paragraph."""
    pieces, i = [], 0
    for u in utterances:
        n = len(u["text"].split())
        chunk = words[i:i + n]
        if " ".join(w["text"] for w in chunk) != u["text"]:
            return utterances          # not built from these words; score at utterance level
        i += n
        current = []
        for w in chunk:
            current.append(w)
            if len(current) >= size or w["text"][-1:] in ".?!":
                pieces.append({"speaker": u["speaker"], "start": current[0]["start"], "end": current[-1]["end"],
                               "text": " ".join(x["text"] for x in current)})
                current = []
        if current:
            pieces.append({"speaker": u["speaker"], "start": current[0]["start"], "end": current[-1]["end"],
                           "text": " ".join(x["text"] for x in current)})
    return pieces


def score_one(name, ref, turns, utterances, words):
    out = {}
    reference = annotation(ref["lines"])
    hypothesis = annotation(turns)
    for label, collar in (("der", 0.5), ("der_nocollar", 0.0)):   # pyannote's collar is the full width
        metric = DiarizationErrorRate(collar=collar, skip_overlap=False)
        d = metric(reference, hypothesis, detailed=True)
        out[label] = {"ref": d["total"], "miss": d["missed detection"], "fa": d["false alarm"], "conf": d["confusion"]}
        out[label]["rate"] = (d["missed detection"] + d["false alarm"] + d["confusion"]) / d["total"] if d["total"] else 0.0
        if label == "der":
            out["mapping"] = metric.optimal_mapping(reference, hypothesis)
    out["ref_speakers"] = len({l["speaker"] for l in ref["lines"]})
    out["hyp_speakers"] = len({t["speaker"] for t in turns})

    r, h = seglst(name, ref["lines"]), seglst(name, timed_pieces(utterances, words))
    if len(h) == 0:
        n = sum(len(x["words"].split()) for x in r)
        out["tcp"] = out["tcorc"] = {"errors": n, "length": n, "insertions": 0, "deletions": n, "substitutions": 0}
        return out
    tcp = meeteval.wer.tcpwer(r, h, collar=5)[name]
    out["tcp"] = {"errors": tcp.errors, "length": tcp.length, "insertions": tcp.insertions,
                  "deletions": tcp.deletions, "substitutions": tcp.substitutions}
    try:
        # One output stream: every word the recognizer wrote, regardless of whose turn it was put in.
        single = SegLST.new([{**row, "speaker": "all"} for row in h])
        orc = meeteval.wer.tcorcwer(r, single, collar=5)[name]
        out["tcorc"] = {"errors": orc.errors, "length": orc.length, "insertions": orc.insertions,
                        "deletions": orc.deletions, "substitutions": orc.substitutions}
    except Exception as e:  # the assignment search can be too large for unusual inputs
        out["tcorc"] = None
        out["tcorc_error"] = str(e)[:200]
    return out


def pooled(rows):
    """Pools meetings the standard way: total errors over total reference length."""
    out = {"meetings": len(rows)}
    for key in ("der", "der_nocollar"):
        ref_time = sum(r[key]["ref"] for r in rows) or 1
        out[key] = sum(r[key]["miss"] + r[key]["fa"] + r[key]["conf"] for r in rows) / ref_time
        if key == "der":
            out["missed"] = sum(r[key]["miss"] for r in rows) / ref_time
            out["false_alarm"] = sum(r[key]["fa"] for r in rows) / ref_time
            out["confusion"] = sum(r[key]["conf"] for r in rows) / ref_time
    for key in ("tcp", "tcorc"):
        ok = [r for r in rows if r.get(key)]
        out[key] = sum(r[key]["errors"] for r in ok) / (sum(r[key]["length"] for r in ok) or 1)
    out["count_exact"] = sum(1 for r in rows if r["hyp_speakers"] == r["ref_speakers"]) / len(rows)
    out["count_within1"] = sum(1 for r in rows if abs(r["hyp_speakers"] - r["ref_speakers"]) <= 1) / len(rows)
    out["count_bias"] = sum(r["hyp_speakers"] - r["ref_speakers"] for r in rows) / len(rows)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("--variants", default="")
    ap.add_argument("--json", default="")
    ap.add_argument("--per-meeting", action="store_true")
    a = ap.parse_args()

    meetings = load(a.dirs)
    if not meetings:
        sys.exit("no <meeting>.result.json with a matching .ref.json found")
    names = ["main"] + sorted({v for res, _ in meetings.values() for v in res.get("variants", {})})
    if a.variants:
        names = [n for n in a.variants.split(",") if n in names]

    table = collections.defaultdict(list)
    for meeting, (res, ref) in sorted(meetings.items()):
        for variant in names:
            src = res if variant == "main" else res.get("variants", {}).get(variant)
            if src is None:
                continue
            s = score_one(meeting, ref, src["turns"], src["utterances"], res["words"])
            s["meeting"], s["variant"] = meeting, variant
            s["seconds"] = res.get("audioSeconds")
            s["speed_separation"] = res.get("audioSeconds", 0) / max(src.get("separationSeconds", 0) or 1e-9, 1e-9)
            s["speed_transcription"] = res.get("audioSeconds", 0) / max(res.get("transcriptionSeconds", 0) or 1e-9, 1e-9)
            table[variant].append(s)
            if a.per_meeting:
                print(f"{meeting:12s} {variant:8s} spk {s['hyp_speakers']}/{s['ref_speakers']}  DER {s['der']['rate']*100:5.1f}  "
                      f"tcORC {100*s['tcorc']['errors']/max(s['tcorc']['length'],1) if s.get('tcorc') else float('nan'):5.1f}  "
                      f"tcpWER {100*s['tcp']['errors']/max(s['tcp']['length'],1):5.1f}", flush=True)

    summary = {}
    print(f"\n{'variant':10s} {'mtgs':>4s} {'DER':>6s} {'miss':>6s} {'FA':>6s} {'conf':>6s} {'DER0':>6s} {'tcORC':>6s} {'tcpWER':>6s} {'count=':>6s} {'±1':>5s} {'bias':>5s}")
    for variant in names:
        rows = table[variant]
        if not rows:
            continue
        p = pooled(rows)
        summary[variant] = p
        print(f"{variant:10s} {p['meetings']:4d} {p['der']*100:6.1f} {p['missed']*100:6.1f} {p['false_alarm']*100:6.1f} {p['confusion']*100:6.1f} "
              f"{p['der_nocollar']*100:6.1f} {p['tcorc']*100:6.1f} {p['tcp']*100:6.1f} {p['count_exact']*100:5.0f}% {p['count_within1']*100:4.0f}% {p['count_bias']:+5.2f}")

    by_size = collections.defaultdict(list)
    for r in table[names[0]]:
        by_size[r["ref_speakers"]].append(r)
    print(f"\n{names[0]} by number of people speaking:")
    sizes = {}
    for n in sorted(by_size):
        p = pooled(by_size[n])
        sizes[n] = p
        print(f"  {n} people: {p['meetings']:3d} meetings  DER {p['der']*100:5.1f}  tcORC {p['tcorc']*100:5.1f}  tcpWER {p['tcp']*100:5.1f}  "
              f"count exact {p['count_exact']*100:3.0f}%  bias {p['count_bias']:+.2f}")

    if a.json:
        detail = {v: [{k: r[k] for k in ("meeting", "ref_speakers", "hyp_speakers", "seconds", "speed_separation", "speed_transcription")}
                      | {"der": r["der"]["rate"], "mapping": r.get("mapping"),
                         "tcp": r["tcp"]["errors"] / max(r["tcp"]["length"], 1),
                         "tcorc": (r["tcorc"]["errors"] / max(r["tcorc"]["length"], 1)) if r.get("tcorc") else None}
                      for r in rows] for v, rows in table.items()}
        json.dump({"summary": summary, "by_speakers": sizes, "meetings": detail}, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
