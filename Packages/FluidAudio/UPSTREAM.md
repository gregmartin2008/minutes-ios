# FluidAudio, vendored

Source: https://github.com/FluidInference/FluidAudio at tag v0.17.7 (commit 503b4bd), Apache 2.0.

Only `Sources/`, `LICENSE` and `ThirdPartyLicenses/` are copied; the CLI, tests, examples and
documentation are not. Changes:

- `Sources/FluidAudio/Diarizer/Offline/Core/PreparedDiarization+Pieces.swift`: joins prepared
  diarization results computed on consecutive pieces of a recording into one, so that the
  segmentation and voice-embedding work can be done while the meeting is still being recorded.

- `Sources/FluidAudio/ASR/Parakeet/SlidingWindow/CustomVocabulary/WordSpotting/CtcModels.swift`:
  `load` and `downloadAndLoad` take an optional `computeUnits`, so the CTC model can be kept off
  the Neural Engine (compiling it there crashed inside Core ML on iOS 27).

- `Sources/FluidAudio/Shared/Download/ModelHub.swift`: records how long each Core ML model took
  to load (`takeLoadTimings()`), for the app's diagnostics.

To update: copy the new `Sources/` over, re-apply the changes above, bump the version here.
