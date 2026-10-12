#!/usr/bin/env python3
"""Downloads meetings from Microsoft's NOTSOFAR-1 corpus for measuring accuracy.

NOTSOFAR-1 is recordings of real meetings of four to eight people in ordinary conference rooms,
each captured by single far-field devices on the table (the situation Minutes is used in), with
human reference transcripts. It is published by Microsoft under CC BY 4.0.

For each meeting this saves one single-channel table-device recording and the reference:
    <out>/<meeting>.wav
    <out>/<meeting>.ref.json   {"meeting", "device", "speakers": [...], "lines": [{speaker,start,end,text,words}]}
    <out>/files.tsv            "<wav path>\t<number of speakers>" per meeting, for minutes-bench --list

usage: fetch_notsofar.py --subset benchmark-datasets/dev_set/240825.1_dev1 --out DIR [--shard 0/4] [--limit N]
"""
import argparse, json, os, re, sys, time, urllib.parse, urllib.request

API = "https://huggingface.co/api/datasets/microsoft/NOTSOFAR/tree/main/"
RESOLVE = "https://huggingface.co/datasets/microsoft/NOTSOFAR/resolve/main/"


def get(url, tries=4):
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                return r.read(), r.headers
        except Exception as e:  # network hiccups and rate limits are retried
            if attempt == tries - 1:
                raise
            time.sleep(3 * (attempt + 1))


def tree(path, recursive=False):
    url = API + urllib.parse.quote(path) + "?limit=1000" + ("&recursive=true" if recursive else "")
    out = []
    while url:
        body, headers = get(url)
        out += json.loads(body)
        m = re.search(r'<([^>]+)>;\s*rel="next"', headers.get("Link") or "")
        url = m.group(1) if m else None
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--subset", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--shard", default="0/1")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--device", default="", help="prefer devices whose folder name contains this")
    a = ap.parse_args()
    shard, shards = [int(x) for x in a.shard.split("/")]
    os.makedirs(a.out, exist_ok=True)

    meetings = sorted(e["path"].split("/")[-1] for e in tree(a.subset + "/MTG") if e["type"] == "directory")
    if a.limit:
        meetings = meetings[: a.limit]
    mine = meetings[shard::shards]
    print(f"{len(meetings)} meetings in {a.subset}; this shard takes {len(mine)}", flush=True)

    rows = []
    for meeting in mine:
        base = f"{a.subset}/MTG/{meeting}"
        try:
            devices = sorted(
                e["path"].split("/")[-1] for e in tree(base) if e["type"] == "directory" and e["path"].split("/")[-1].startswith("sc_"))
            if not devices:
                print(f"{meeting}: no single-channel device, skipped", flush=True)
                continue
            preferred = [d for d in devices if a.device and a.device in d]
            device = (preferred or devices)[0]
            gt = json.loads(get(RESOLVE + urllib.parse.quote(f"{base}/gt_transcription.json"))[0])
            meta = json.loads(get(RESOLVE + urllib.parse.quote(f"{base}/gt_meeting_metadata.json"))[0])
            wav = get(RESOLVE + urllib.parse.quote(f"{base}/{device}/ch0.wav"))[0]
        except Exception as e:
            print(f"{meeting}: download failed ({e}), skipped", flush=True)
            continue

        lines = []
        for seg in gt:
            words = [{"text": w[0], "start": float(w[1]), "end": float(w[2])} for w in seg.get("word_timing") or []]
            lines.append({
                "speaker": seg["speaker_id"], "start": float(seg["start_time"]), "end": float(seg["end_time"]),
                "text": seg.get("text") or "", "words": words,
            })
        lines.sort(key=lambda l: l["start"])
        speakers = sorted({l["speaker"] for l in lines})
        wav_path = os.path.join(a.out, meeting + ".wav")
        with open(wav_path, "wb") as f:
            f.write(wav)
        with open(os.path.join(a.out, meeting + ".ref.json"), "w") as f:
            json.dump({
                "meeting": meeting, "device": device, "devices": devices, "speakers": speakers,
                "participants": meta.get("NumParticipants"), "seconds": meta.get("MeetingDurationSec"),
                "room": meta.get("Room"), "topic": meta.get("Topic"), "tags": meta.get("Hashtags"), "lines": lines,
            }, f)
        rows.append(f"{wav_path}\t{len(speakers)}")
        print(f"{meeting}: {device}, {len(speakers)} speakers, {len(lines)} segments, {len(wav) / 32000:.0f}s", flush=True)

    with open(os.path.join(a.out, "files.tsv"), "w") as f:
        f.write("\n".join(rows) + ("\n" if rows else ""))
    if not rows:
        sys.exit("nothing was downloaded")


if __name__ == "__main__":
    main()
