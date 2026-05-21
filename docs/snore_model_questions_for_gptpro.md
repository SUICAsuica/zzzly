# zzzly Snore Detection: Questions for GPT Pro

## Context

zzzly is an iOS app that records overnight audio locally and estimates whether the user snored.

The app currently shows a very simple result:

- Red: likely snored
- Yellow: borderline
- Blue: safe

The current implementation uses a Core ML model named `SnoreCNN`.

## Current Model

Model metadata:

- Model: `SnoreCNN`
- Input: normalized `64 x 96` log-mel spectrogram
- Sample rate: `16,000 Hz`
- Window size: `1.0 sec`
- Datasets:
  - ESC-50
  - Kaggle Snoring 1s
  - Kaggle Snoring 10s segmented into 1s windows
  - Kaggle Respiratory Sound Database as non-snoring negatives
- Metadata labels:
  - `0`: `non_snoring`
  - `1`: `snoring`
- Test accuracy: `0.9209`
- Snoring precision: `0.8892`
- Snoring recall: `0.8934`
- Snoring F1: `0.8913`
- Training device: RTX 4060 Ti

## Current iOS Inference Path

The iOS app:

1. Records audio with `AVAudioEngine`.
2. Chunks audio into 1-second windows.
3. Resamples to `16 kHz`.
4. Converts each second into a `64 x 96` log-mel spectrogram in Swift.
5. Sends the input as:

```swift
MLMultiArray(shape: [1, 1, 64, 96], dataType: .float32)
```

with feature name:

```swift
logmel
```

6. Reads model output:

```swift
var_80
```

The current app uses `var_80[0]` as the snore probability.

Current per-second decision:

```swift
isSnore = var_80[0] >= 0.75 && db > -55
```

The final red/yellow/blue result uses the ratio of `isSnore` seconds:

```swift
red    if snoreRatio >= 0.16
yellow if snoreRatio >= 0.07
blue   otherwise
```

## Why This Is Suspicious

Recent real overnight iPhone logs show that `var_80[0]` is almost always high.

Example observations:

- Median model score is often around `0.89`.
- Many nights have almost every second above `0.75`.
- The final app result is still blue because the `db > -55` gate filters nearly everything out.

This means the model score is currently not very discriminative in production. The app is effectively being driven mostly by the dB gate.

## Real User Data Summary

Recent exported sessions:

### 2026-05-18 night

- Recording: `23:25 - 06:30`
- Duration: `7h05m`
- App verdict: `safe`
- Current logic detected:
  - `60 sec`
  - `0.24%`
- If using `probability >= 0.75 && db > -60`:
  - `171 sec`
  - `0.67%`
- If using `probability >= 0.75 && db > -65`:
  - `928 sec`
  - `3.64%`
- Model score:
  - median around `0.8985`
  - 90th percentile around `0.9032`
  - max around `0.9174`

### 2026-05-19 night

- Recording: `01:08 - 06:10`
- Duration: `5h01m`
- App verdict: `safe`
- Current logic detected:
  - `22 sec`
  - `0.12%`
- If using `probability >= 0.75 && db > -60`:
  - `41 sec`
  - `0.23%`
- If using `probability >= 0.75 && db > -65`:
  - `76 sec`
  - `0.42%`
- Model score:
  - median around `0.8915`
  - 90th percentile around `0.8978`
  - max around `0.9141`

### 2026-05-20 night

- Recording: `00:56 - 05:49`
- Duration: `4h53m`
- App verdict: `safe`
- Current logic detected:
  - `16 sec`
  - `0.09%`
- If using `probability >= 0.75 && db > -60`:
  - `41 sec`
  - `0.23%`
- If using `probability >= 0.75 && db > -65`:
  - `86 sec`
  - `0.49%`
- Saved suspicious audio clips:
  - `86`
- Model score:
  - median around `0.8964`
  - 90th percentile around `0.9000`
  - max around `0.9129`

### 2026-05-21 night

- Recording: `01:25 - 06:20`
- Duration: `4h55m`
- App verdict: `safe`
- Current logic detected:
  - `5 sec`
  - `0.03%`
- If using `probability >= 0.75 && db > -60`:
  - `12 sec`
  - `0.07%`
- If using `probability >= 0.75 && db > -65`:
  - `58 sec`
  - `0.33%`
- Saved suspicious audio clips:
  - `58`
- Model score:
  - median around `0.8972`
  - 90th percentile around `0.9012`
  - max around `0.9172`

## Main Questions

### 1. Is the output index interpretation wrong?

The metadata says:

- index `0`: non-snoring
- index `1`: snoring

But earlier testing suggested `var_80[0]` might correspond to snoring.

Now real overnight data shows `var_80[0]` is almost always around `0.89`, even when the final result is safe and dB is very low.

Question:

- Is `var_80[0]` actually non-snoring probability?
- Should the app use `var_80[1]` instead?
- How should we verify this rigorously with the saved wav clips?

### 2. Is Swift log-mel preprocessing mismatched with training preprocessing?

The Swift implementation computes log-mel manually.

Potential mismatch points:

- mel filter formula
- Slaney vs HTK mel scale
- FFT size
- hop length
- windowing
- log scaling
- reference dB normalization
- input layout `[1, 1, 64, 96]`
- whether training used per-sample normalization, dataset normalization, or librosa defaults

Question:

- Could preprocessing mismatch explain why scores are always high?
- What exact comparison should be done between Python preprocessing and Swift preprocessing?

### 3. Is the model overconfident on quiet iPhone night audio?

The model may not have enough examples of:

- actual iPhone bedside silence
- air conditioner noise
- bedsheet movement
- distant room noise
- quiet breathing
- microphone noise floor

Question:

- Is the model likely suffering from dataset shift?
- Should the training set include real negative examples from this device/environment?
- Should we collect hard negatives from saved clips?

### 4. Is dB gating doing too much work?

Current decision:

```swift
var_80[0] >= 0.75 && db > -55
```

In real logs:

- `var_80[0] >= 0.75` is true almost all night.
- `db > -55` is rare.

So final detection is mostly based on dB.

Question:

- Is this acceptable as a temporary heuristic?
- Should the app use a dB-relative threshold instead of an absolute threshold?
- Example: compare each second against the nightly noise floor, such as `db > medianDb + 12`.

### 5. Is the final red/yellow/blue aggregation too simple?

Current aggregation is only snore seconds ratio:

```swift
red    >= 16%
yellow >= 7%
blue   otherwise
```

This may miss:

- short but obvious snore bursts
- clusters concentrated in a few periods
- repeated events
- long continuous low-volume snoring

Question:

- Should final verdict use a combination of:
  - total snore seconds
  - longest continuous run
  - number of events
  - cluster density per minute
  - peak dB
  - confidence
  - manually confirmed audio labels?

### 6. What should the next calibration workflow be?

The app now saves suspicious 1-second wav clips under:

```text
Documents/zzzly-training/<session>/segments/
```

and links them from:

```text
manifest.csv -> audio_file
```

Saved clips are selected when:

```swift
is_snore == 1 || (probability >= 0.75 && db > -65)
```

Question:

- What is the best labeling workflow for these clips?
- How many clips are needed before changing thresholds?
- How many labeled personal clips are needed before fine-tuning/retraining?

## Requested Output from GPT Pro

Please analyze the above and recommend:

1. Whether the app should use `var_80[0]` or `var_80[1]`.
2. How to verify the correct class index using saved clips.
3. Whether the Swift log-mel preprocessing is likely mismatched.
4. A better temporary detection rule for the next few nights.
5. A better red/yellow/blue aggregation formula.
6. A practical personal-data labeling and retraining plan.
7. What metrics should be reported after calibration.

