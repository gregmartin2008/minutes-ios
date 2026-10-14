#!/usr/bin/env python3
"""Builds a synthetic six-person meeting with crosstalk, using the Mac's built-in voices.

It is a smoke test for the speech pipeline, not an accuracy benchmark: synthetic voices in a silent
room are far easier than a real conference table. Writes meeting.wav (16 kHz mono), meeting.rttm
(who spoke when) and meeting.ref.json (who said what).
"""
import array, json, os, subprocess, sys, tempfile, wave

RATE = 16000
out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(out_dir, exist_ok=True)

# (speaker, seconds relative to the end of the previous line (negative = talk over it), text)
SCRIPT = [
    ("A", 0.6, "Thanks everyone for making time. I want to walk through where we landed on the diligence before we talk about price."),
    ("B", 0.5, "Sure. The headline for me is customer concentration. The top ten customers are a large share of revenue, but the contracts run for several years."),
    ("C", 0.4, "I looked at the renewal history. Nobody in the top ten has left in the last five years, which is reassuring."),
    ("A", 0.5, "Good. What about the working capital target? The seller keeps pushing back on our number."),
    ("D", 0.4, "They want it based on the trailing twelve months. We think the seasonal average is the fair measure."),
    ("E", -0.9, "Can I jump in on that point? The seasonal swing is bigger than their model shows."),
    ("D", 0.3, "Right, that is exactly the problem with their approach."),
    ("F", 0.5, "From the lender side, the bank will want to see the covenant package before the end of the month."),
    ("B", 0.4, "Then I would hold the bid where it is until the customer calls are finished."),
    ("C", -0.7, "Agreed, I would not move on price yet."),
    ("A", 0.5, "Okay. Who is taking the reference calls with the customers?"),
    ("E", 0.4, "I will schedule three of them this week and report back on Friday."),
    ("F", 0.4, "I can send the revised financing schedule to the group tomorrow morning."),
    ("A", 0.5, "Perfect. Let us also make sure legal reviews the transition services agreement."),
    ("D", 0.4, "I will ask outside counsel to mark it up and send comments by Thursday."),
    ("B", -1.0, "And please include the environmental report in that review as well."),
    ("C", 0.5, "One open question is whether the founder stays on after closing. He has not committed either way."),
    ("E", 0.4, "My read is that he wants to stay for two years, but he wants that written into the agreement."),
    ("A", 0.5, "Then we should offer an employment agreement and see how he responds."),
    ("F", 0.4, "That works for the bank. They prefer continuity in management for the first year at least."),
    ("B", 0.5, "Last thing from me. The quality of earnings report arrives next Wednesday."),
    ("D", 0.4, "And Soterra should confirm with Kestrel that the lowboy order book stays open through the signing."),
    ("A", 0.4, "Great. We will meet again after that report comes in. Thank you all."),
]

def voices():
    listing = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    novelty = {"Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Good News", "Jester", "Organ",
               "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox", "Junior", "Ralph", "Fred", "Kathy"}
    found = []
    for line in listing.splitlines():
        parts = line.split("#")[0].rsplit(None, 1)
        if len(parts) != 2:
            continue
        name, locale = parts[0].strip(), parts[1].strip()
        if locale.startswith("en_") and name not in novelty and "(" not in name:
            found.append(name)
    preferred = ["Samantha", "Daniel", "Karen", "Rishi", "Moira", "Tessa", "Aaron", "Nicky", "Alex", "Victoria"]
    ordered = [v for v in preferred if v in found] + [v for v in found if v not in preferred]
    return ordered

def synth(voice, text, path):
    subprocess.run(["say", "-v", voice, "-o", path, "--data-format=LEI16@16000", text], check=True)
    with wave.open(path, "rb") as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2, "unexpected say output"
        return array.array("h", w.readframes(w.getnframes()))

def trim(samples, floor=200):
    """Drop leading and trailing near-silence so the reference times hug the speech."""
    start, end = 0, len(samples)
    while start < end and abs(samples[start]) < floor: start += 1
    while end > start and abs(samples[end - 1]) < floor: end -= 1
    return samples[max(0, start - 160):min(len(samples), end + 160)]

available = voices()
speakers = sorted({s for s, _, _ in SCRIPT})
if len(available) < len(speakers):
    sys.exit(f"need {len(speakers)} English voices, found {len(available)}: {available}")
voice_of = dict(zip(speakers, available))
print("voices:", voice_of)

mix = array.array("l")
reference = []
cursor = 0.0
tmp = tempfile.mkdtemp()
for i, (speaker, gap, text) in enumerate(SCRIPT):
    clip = trim(synth(voice_of[speaker], text, os.path.join(tmp, f"{i}.wav")))
    start = max(0.0, cursor + gap)
    first = int(start * RATE)
    need = first + len(clip)
    if len(mix) < need:
        mix.extend([0] * (need - len(mix)))
    # Talk-over lines are a little quieter, as an interjection from across the table would be.
    scale = 0.8 if gap < 0 else 1.0
    for j, v in enumerate(clip):
        mix[first + j] += int(v * scale)
    end = start + len(clip) / RATE
    reference.append({"speaker": speaker, "start": round(start, 3), "end": round(end, 3), "text": text})
    cursor = max(cursor, end)

mix.extend([0] * RATE)
pcm = array.array("h", (max(-32768, min(32767, v)) for v in mix))
with wave.open(os.path.join(out_dir, "meeting.wav"), "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(pcm.tobytes())
with open(os.path.join(out_dir, "meeting.rttm"), "w") as f:
    for r in reference:
        f.write(f"SPEAKER meeting 1 {r['start']:.3f} {r['end'] - r['start']:.3f} <NA> <NA> {r['speaker']} <NA> <NA>\n")
json.dump({"voices": voice_of, "lines": reference}, open(os.path.join(out_dir, "meeting.ref.json"), "w"), indent=1)

overlap = 0.0
ordered = sorted(reference, key=lambda r: r["start"])
for a, b in zip(ordered, ordered[1:]):
    overlap += max(0.0, min(a["end"], b["end"]) - b["start"])
print(f"wrote {len(pcm) / RATE:.1f}s, {len(speakers)} speakers, {len(reference)} lines, {overlap:.1f}s of crosstalk")
