# zzzly

Minimal iOS snore check app.

## Flow

- Open the app before sleeping.
- The app automatically keeps a microphone session active and samples sound level / low-frequency-like frames.
- Open the app again in the morning.
- The screen is only one primary color:
  - Red: likely snoring
  - Yellow: borderline
  - Blue: safe

## Paid Element

StoreKit scaffolding is kept in the project, and the visible result screen stays almost zero. After a morning result, a small `分析` entry opens the paid report. This is intended as a one-time non-consumable purchase. The product ID reserved in code is:

```text
zzzly.deep_report
```

Create this non-consumable product in App Store Connect, then replace pricing / wording there. The implementation lives in:

- `zzzly/PurchaseManager.swift`
- `zzzly/ContentView.swift`

Paid analysis currently shows:

- recorded duration
- estimated snore duration
- snore ratio
- detected snore range from the start of recording
- estimated snore event count
- longest continuous snore run
- average / maximum model confidence
- peak dB
- saved training segment count
- whether ML or fallback audio heuristics produced the result

## Local Training Capture

Temporary local data collection is enabled in `zzzly/TrainingDataRecorder.swift`. During a night it saves every 1-second inference result into a CSV manifest in the app Documents folder. It does not save audio:

```text
Documents/zzzly-training/YYYYMMDD-HHmmss/
  manifest.csv
  session.json
  result.json
```

The manifest contains window index, seconds from start, snore probability, binary snore decision, dB, zero-crossing rate, and source sample rate. The current cap is 60,000 rows per night.

`UIFileSharingEnabled` is enabled, so the folder can be retrieved from the device app container for threshold tuning and trend analysis.

## Snore ML

`models/SnoreCNN.mlpackage` is copied into the app as `zzzly/SnoreCNN.mlpackage` and compiled by Xcode into `SnoreCNN.mlmodelc`.

Runtime path:

- `zzzly/SnoreMonitor.swift` collects 1-second audio windows.
- `zzzly/SnoreAudioClassifier.swift` converts audio into a normalized `64x96` log-mel spectrogram.
- Core ML input: `logmel` with shape `[1, 1, 64, 96]`.
- Core ML output: `var_80` with shape `[1, 2]`; runtime treats index `0` as snoring probability.
- Per-second snore decision: `index0 >= 0.75 && db > -55`.

Feature parity check:

```sh
uv run python ml/compare_feature_pipeline.py
```

The old Swift-like extractor drifted from the librosa baseline on a snore sample:

- MAE `0.073296`
- correlation `0.879138`

The corrected extractor settings now match the baseline candidate:

- `sr=16000`
- `n_fft=512`
- `hop_length=160`
- `n_mels=64`
- `fmin=40`
- `fmax=4000`
- `center=false`
- Slaney mel scale / Slaney normalization
- first `96` frames
- `power_to_db(ref=np.max)` then `(db + 80) / 80`

The parity script reported the corrected candidate at:

- MAE `0.000182`
- correlation `0.999999`

## Build

```sh
xcodebuild -project zzzly.xcodeproj -scheme zzzly -destination 'generic/platform=iOS Simulator' build
```
