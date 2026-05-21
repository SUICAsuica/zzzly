# zzzly Snore ML

Goal: train a tiny on-device classifier for `snore` vs `non_snore`, then convert it to Core ML.

## Dataset Plan

Start with:

- ESC-50: includes a `snoring` class and many non-snore environmental classes. Good for a prototype, but only 40 snoring clips.
- Kaggle "Snoring Dataset": larger snore-specific candidate, but requires Kaggle access and license review.
- PhysioNet CPS / PSG datasets: useful clinically, but access/licensing and signal format are heavier than a phone-audio MVP.

For v0, train on ESC-50:

- Positive: `snoring`
- Negative: `breathing`, `coughing`, `sneezing`, `brushing_teeth`, `clock_tick`, `door_wood_creaks`, `washing_machine`, `vacuum_cleaner`, `rain`, `wind`, `footsteps`, etc.

Then improve with app-collected hard negatives:

- blanket rustle
- phone handling
- charger/table vibration
- air conditioner
- fan
- speech / TV

## Commands

```sh
uv venv
uv pip install -r ml/requirements.txt
uv run python ml/download_esc50.py
uv run python ml/train_snore_classifier.py
```

The training script writes:

- `models/zzzly_snore.keras`
- `models/zzzly_snore.mlpackage` when `coremltools` conversion succeeds

## iOS Integration Target

The app should eventually replace the current hand-written threshold logic in `SnoreMonitor.swift` with:

- record 1-second windows
- extract log-mel spectrogram
- classify with Core ML
- count windows whose `snore` probability exceeds a threshold
- map total snore time to red / yellow / blue
