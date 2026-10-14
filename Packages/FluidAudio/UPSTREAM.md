# FluidAudio, vendored

Source: https://github.com/FluidInference/FluidAudio at tag v0.17.7 (commit 503b4bd), Apache 2.0.

Only `Sources/`, `LICENSE` and `ThirdPartyLicenses/` are copied; the CLI, tests, examples and
documentation are not. One file is added:

- `Sources/FluidAudio/Diarizer/Offline/Core/PreparedDiarization+Pieces.swift`: joins prepared
  diarization results computed on consecutive pieces of a recording into one, so that the
  segmentation and voice-embedding work can be done while the meeting is still being recorded.

To update: copy the new `Sources/` over, re-apply the file above, bump the version here.
