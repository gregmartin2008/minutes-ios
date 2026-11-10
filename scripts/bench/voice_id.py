#!/usr/bin/env python3
"""How well would Minutes recognize people from one meeting to the next?

Uses what a benchmark run already published: each meeting's per-speaker voice embeddings
(*.result.json, "voices") and the scorer's mapping from separated speakers to the corpus's
named people (score.py --json). Plays the meetings in order the way the app meets them: a
person is enrolled the first time they are named, later voices are matched against the
profiles with the app's rules, and a third of the people are held out as strangers who are
never enrolled. No audio and no models are needed, so it runs in seconds.

    python3 score.py results --variants main --json scores.json
    python3 voice_id.py results scores.json
"""
import glob
import json
import sys

import numpy as np


def load(results_dir, scores_path):
    scores = {m["meeting"]: m for m in json.load(open(scores_path))["meetings"]["main"]}
    meetings = []
    for path in sorted(glob.glob(f"{results_dir}/*.result.json")):
        name = path.split("/")[-1][: -len(".result.json")]
        if name not in scores:
            continue
        result = json.load(open(path))
        heard = {t["speaker"] for t in result["turns"]}
        voices = {k: np.array(v, dtype=np.float64) for k, v in result["voices"].items() if k in heard}
        for k in voices:
            voices[k] /= np.linalg.norm(voices[k]) or 1
        meetings.append((voices, scores[name]["mapping"]))
    return meetings


class Profile:
    """One running average per person, as SpeakerProfile.absorb keeps it (weight capped at 8)."""

    def __init__(self, e):
        self.e, self.n = e.copy(), 1

    def score(self, e):
        return float(self.e @ e)

    def absorb(self, e):
        w = min(max(self.n, 1), 8)
        m = self.e * w + e
        self.e, self.n = m / np.linalg.norm(m), self.n + 1


def match(voices, profiles, accept, margin, first_accept, suggest=0.45):
    """SpeakerMatcher.match: best pairs first, one voice per person, a name only when clear."""
    names, labels = list(profiles), list(voices)
    if not names or not labels:
        return {}
    S = np.array([[profiles[n].score(voices[l]) for n in names] for l in labels])
    pairs = sorted(((S[i, j], i, j) for i in range(len(labels)) for j in range(len(names)) if S[i, j] >= suggest), reverse=True)
    used_voice, used_person, out = set(), set(), {}
    for s, i, j in pairs:
        if i in used_voice or j in used_person:
            continue
        used_voice.add(i)
        used_person.add(j)
        rival = max([S[i, k] for k in range(len(names)) if k != j] + [S[k, j] for k in range(len(labels)) if k != i] + [-1])
        need = first_accept if profiles[names[j]].n == 1 else accept
        out[labels[i]] = (names[j], float(s), bool(s >= need and s - rival >= margin))
    return out


def run(meetings, strangers, accept, margin, learn_from, first_accept):
    profiles = {}
    c = dict(known=0, right=0, wrong=0, suggested=0, blank=0, strangers=0, stranger_named=0)
    for voices, mapping in meetings:
        found = match(voices, profiles, accept, margin, first_accept)
        for label in voices:
            who, got = mapping.get(label), found.get(label)
            if who is None or who in strangers:
                c["strangers"] += 1
                c["stranger_named"] += bool(got and got[2])
            elif who in profiles:
                c["known"] += 1
                if got is None:
                    c["blank"] += 1
                elif not got[2]:
                    c["suggested"] += 1
                else:
                    c["right" if got[0] == who else "wrong"] += 1
        for label, e in voices.items():
            who, got = mapping.get(label), found.get(label)
            if who is None or who in strangers:
                continue
            if who not in profiles:
                profiles[who] = Profile(e)                       # named by the person, once
            elif not (got and got[2] and got[0] == who):
                profiles[who].absorb(e)                          # the person names what the app missed
            elif learn_from is not None and got[1] >= learn_from:
                profiles[who].absorb(e)                          # the app learns from its own sure matches
    return c


def report(meetings, tag, accept=0.70, margin=0.12, learn_from=None, first_accept=None):
    people = sorted({v for _, mapping in meetings for v in mapping.values()})
    total = {}
    for fold in range(3):                                        # each person is a stranger in one run
        for k, v in run(meetings, set(people[fold::3]), accept, margin, learn_from, first_accept or accept).items():
            total[k] = total.get(k, 0) + v
    k, s = total["known"], max(total["strangers"], 1)
    print(f"{tag:44s} named right {100 * total['right'] / k:5.1f}%  wrong {100 * total['wrong'] / k:4.1f}%  "
          f"suggested {100 * total['suggested'] / k:4.1f}%  blank {100 * total['blank'] / k:4.1f}%  |  strangers given a name {100 * total['stranger_named'] / s:4.1f}%")


if __name__ == "__main__":
    M = load(sys.argv[1], sys.argv[2])
    print(f"{len(M)} meetings")
    report(M, "the app today")
    report(M, "learning from matches of 0.80 or more", learn_from=0.80)
    report(M, "the same, one-meeting profiles need 0.80", learn_from=0.80, first_accept=0.80)
