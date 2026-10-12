#!/usr/bin/env python3
"""Downloads long recorded meetings with reference transcripts from two public research corpora.

  icsi  The ICSI Meeting Corpus: real research-group meetings of three to ten people, most about
        an hour long. Audio is the mix of the participants' headset microphones (clear sound, real
        overlapping speech). Used here to measure meetings with many speakers at full length.
  ami   The AMI Meeting Corpus: four-person meetings. Audio is one far-field table microphone
        (`Array1-01`), the usual "single distant microphone" test condition.
Both are distributed by the University of Edinburgh under CC BY 4.0.

For each meeting this writes <out>/<meeting>.wav, <out>/<meeting>.ref.json and a line in
<out>/files.tsv, in the same form as fetch_notsofar.py.

usage: fetch_nxt.py --corpus icsi|ami --meetings Bmr021,Bed016 --out DIR [--shard 0/2]
                    [--clips 360,720] [--no-full]
--clips also writes the first N seconds of each meeting as its own recording (<meeting>_c<N>), to
measure how the length of a recording affects the result; --no-full then leaves out the whole one.
"""
import argparse, io, json, os, re, struct, sys, time, urllib.request, zipfile
from concurrent.futures import ThreadPoolExecutor
import xml.etree.ElementTree as ET

BASE = "https://groups.inf.ed.ac.uk/ami/"
CORPORA = {
    "icsi": {
        "zip": BASE + "ICSICorpusAnnotations/ICSI_core_NXT.zip",
        "words": "ICSI/Words/{m}.{s}.words.xml",
        "audio": BASE + "ICSIsignals/NXT/{m}.interaction.wav",
        "device": "headset mix",
    },
    "ami": {
        "zip": BASE + "AMICorpusAnnotations/ami_public_manual_1.6.2.zip",
        "words": "words/{m}.{s}.words.xml",
        "audio": BASE + "AMICorpusMirror/amicorpus/{m}/audio/{m}.Array1-01.wav",
        "device": "far-field table microphone",
    },
}
NITE = "{http://nite.sourceforge.net/}"


def get(url, tries=4):
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=600) as r:
                return r.read()
        except Exception:
            if attempt == tries - 1:
                raise
            time.sleep(5 * (attempt + 1))


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def read_words(xml_bytes):
    """Words of one speaker in order, with punctuation and contraction pieces folded into words."""
    root = ET.fromstring(xml_bytes)
    words = []
    for el in root:
        if el.tag != "w":
            continue
        text = (el.text or "").strip()
        if not text:
            continue
        start, end = number(el.get("starttime")), number(el.get("endtime"))
        is_punctuation = el.get("punc") == "true" or not re.search(r"[A-Za-z0-9]", text)
        if is_punctuation:
            if words and text in ".?!,":
                words[-1]["text"] += text
            continue
        if text.startswith("'") and words and words[-1]["end"] is None:
            # The second half of a contraction ("I" + "'m"): one spoken word, timed across both pieces.
            words[-1]["text"] += text
            words[-1]["end"] = end
            continue
        words.append({"text": text, "start": start, "end": end})
    # Fill the few missing times from the neighbors.
    for i, w in enumerate(words):
        if w["start"] is None:
            w["start"] = words[i - 1]["end"] if i > 0 and words[i - 1]["end"] is not None else w["end"]
        if w["end"] is None:
            nxt = next((x["start"] for x in words[i + 1:] if x["start"] is not None), None)
            w["end"] = min(nxt, w["start"] + 0.6) if nxt is not None and w["start"] is not None else w["start"]
    return [w for w in words if w["start"] is not None and w["end"] is not None]


def lines_for(speaker, words, pause=0.6):
    lines, current = [], []
    def flush():
        if current:
            lines.append({
                "speaker": speaker, "start": current[0]["start"], "end": max(current[-1]["end"], current[0]["start"]),
                "text": " ".join(w["text"] for w in current),
                "words": [{"text": w["text"], "start": w["start"], "end": w["end"]} for w in current],
            })
            current.clear()
    for w in words:
        if current and (w["start"] - current[-1]["end"] > pause or current[-1]["text"][-1:] in ".?!"):
            flush()
        current.append(w)
    flush()
    return lines


def clip_wav(data, seconds):
    """The first `seconds` of a PCM WAV file, as a new WAV file."""
    pos, fmt, body = 12, None, None
    while pos + 8 <= len(data):
        tag, size = data[pos:pos + 4], struct.unpack("<I", data[pos + 4:pos + 8])[0]
        if tag == b"fmt ":
            fmt = data[pos + 8:pos + 8 + size]
        elif tag == b"data":
            body = data[pos + 8:pos + 8 + size]
            break
        pos += 8 + size + (size & 1)
    if fmt is None or body is None:
        raise ValueError("not a PCM WAV file")
    channels, rate = struct.unpack("<HI", fmt[2:8])
    width = struct.unpack("<H", fmt[14:16])[0] // 8
    keep = int(seconds * rate) * channels * width
    body = body[:keep]
    header = b"RIFF" + struct.pack("<I", 36 + len(body)) + b"WAVE" + b"fmt " + struct.pack("<I", 16) + fmt[:16]
    return header + b"data" + struct.pack("<I", len(body)) + body


def clip_lines(lines, seconds):
    out = []
    for l in lines:
        words = [w for w in l["words"] if w["end"] <= seconds]
        if not words:
            continue
        out.append({"speaker": l["speaker"], "start": l["start"], "end": min(l["end"], seconds, max(w["end"] for w in words)),
                    "text": " ".join(w["text"] for w in words), "words": words})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clips", default="")
    ap.add_argument("--no-full", action="store_true")
    ap.add_argument("--corpus", required=True, choices=sorted(CORPORA))
    ap.add_argument("--meetings", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--shard", default="0/1")
    a = ap.parse_args()
    corpus = CORPORA[a.corpus]
    shard, shards = [int(x) for x in a.shard.split("/")]
    meetings = [m for m in a.meetings.split(",") if m][shard::shards]
    os.makedirs(a.out, exist_ok=True)
    clips = [int(x) for x in a.clips.split(",") if x]

    print(f"downloading {a.corpus} annotations", flush=True)
    archive = zipfile.ZipFile(io.BytesIO(get(corpus["zip"])))
    names = set(archive.namelist())

    # Read the reference words first (quick, from the archive already in memory).
    references = {}
    for m in meetings:
        lines, speakers = [], []
        for s in "ABCDEFGHIJKLMNOP":
            name = corpus["words"].format(m=m, s=s)
            if name not in names:
                continue
            words = read_words(archive.read(name))
            if words:
                speakers.append(s)
                lines += lines_for(s, words)
        if not lines:
            print(f"{m}: no reference words found, skipped", flush=True)
            continue
        lines.sort(key=lambda l: l["start"])
        references[m] = (lines, speakers)

    def fetch(m):
        lines, speakers = references[m]
        try:
            wav = get(corpus["audio"].format(m=m))
        except Exception as e:
            print(f"{m}: audio download failed ({e}), skipped", flush=True)
            return None
        made = []
        if not a.no_full:
            wav_path = os.path.join(a.out, m + ".wav")
            with open(wav_path, "wb") as f:
                f.write(wav)
            with open(os.path.join(a.out, m + ".ref.json"), "w") as f:
                json.dump({"meeting": m, "corpus": a.corpus, "device": corpus["device"], "speakers": speakers, "lines": lines}, f)
            made.append(f"{wav_path}\t{len(speakers)}")
        for seconds in clips:
            part = clip_lines(lines, seconds)
            if not part or lines[-1]["end"] < seconds:
                continue        # the meeting is shorter than this clip
            name = f"{m}_c{seconds}"
            wav_path = os.path.join(a.out, name + ".wav")
            with open(wav_path, "wb") as f:
                f.write(clip_wav(wav, seconds))
            part_speakers = sorted({l["speaker"] for l in part})
            with open(os.path.join(a.out, name + ".ref.json"), "w") as f:
                json.dump({"meeting": name, "corpus": a.corpus, "device": corpus["device"], "clip": seconds,
                           "speakers": part_speakers, "lines": part}, f)
            made.append(f"{wav_path}\t{len(part_speakers)}")
        words_total = sum(len(l["words"]) for l in lines)
        print(f"{m}: {len(speakers)} speakers, {len(lines)} lines, {words_total} words, {len(wav) / 1e6:.0f} MB, ends {lines[-1]['end'] / 60:.0f} min", flush=True)
        return made

    # The archive server is slow per connection, so several recordings are downloaded at once.
    with ThreadPoolExecutor(max_workers=6) as pool:
        rows = [row for made in pool.map(fetch, [m for m in meetings if m in references]) if made for row in made]

    mode = "a" if os.path.exists(os.path.join(a.out, "files.tsv")) else "w"
    with open(os.path.join(a.out, "files.tsv"), mode) as f:
        f.write("\n".join(rows) + ("\n" if rows else ""))
    if not rows:
        sys.exit("nothing was downloaded")


if __name__ == "__main__":
    main()
