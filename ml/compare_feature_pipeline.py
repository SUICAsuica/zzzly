from __future__ import annotations

import csv
from pathlib import Path

import coremltools as ct
import librosa
import numpy as np


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "data" / "esc50_snore_manifest.csv"
MODEL_PATH = ROOT / "models" / "SnoreCNN.mlpackage"

SAMPLE_RATE = 16_000
WINDOW_SAMPLES = 16_000
N_MELS = 64
TARGET_FRAMES = 96
N_FFT = 512
HOP_LENGTH = 160
FMIN = 40
FMAX = 4_000


def load_examples() -> list[tuple[str, str]]:
    with MANIFEST.open(newline="") as f:
        rows = list(csv.DictReader(f))
    snore = next(row for row in rows if row["label"] == "snore")
    non = next(row for row in rows if row["label"] == "non_snore")
    return [(snore["label"], snore["path"]), (non["label"], non["path"])]


def load_audio(path: str) -> np.ndarray:
    y, _ = librosa.load(path, sr=SAMPLE_RATE, mono=True)
    if len(y) < WINDOW_SAMPLES:
        y = np.pad(y, (0, WINDOW_SAMPLES - len(y)))
    return y[:WINDOW_SAMPLES].astype(np.float32)


def reference_logmel(y: np.ndarray) -> np.ndarray:
    mel = librosa.feature.melspectrogram(
        y=y,
        sr=SAMPLE_RATE,
        n_fft=N_FFT,
        hop_length=HOP_LENGTH,
        n_mels=N_MELS,
        fmin=FMIN,
        fmax=FMAX,
        power=2.0,
        center=False,
        norm="slaney",
        htk=False,
    )
    mel = fix_frames(mel)
    logmel = librosa.power_to_db(mel, ref=np.max)
    return np.clip((logmel + 80.0) / 80.0, 0, 1).astype(np.float32)


def swift_like_logmel(y: np.ndarray) -> np.ndarray:
    frame_length = 512
    hop = max(1, (WINDOW_SAMPLES - frame_length) // max(TARGET_FRAMES - 1, 1))
    filters = swift_like_mel_filters(frame_length // 2 + 1)
    all_power = np.zeros((N_MELS, TARGET_FRAMES), dtype=np.float32)

    for frame in range(TARGET_FRAMES):
        start = min(frame * hop, max(0, len(y) - frame_length))
        window = y[start : start + frame_length]
        hann = np.hanning(frame_length).astype(np.float32)
        spectrum = np.abs(np.fft.rfft(window * hann)) ** 2 / frame_length
        all_power[:, frame] = np.maximum(filters @ spectrum.astype(np.float32), 1e-10)

    ref_db = 10 * np.log10(np.max(all_power))
    db = 10 * np.log10(np.maximum(all_power, 1e-10)) - ref_db
    return np.clip((db + 80) / 80, 0, 1).astype(np.float32)


def fixed_swift_candidate(y: np.ndarray) -> np.ndarray:
    frame_length = N_FFT
    filters = librosa.filters.mel(
        sr=SAMPLE_RATE,
        n_fft=N_FFT,
        n_mels=N_MELS,
        fmin=FMIN,
        fmax=FMAX,
        norm="slaney",
        htk=False,
    ).astype(np.float32)
    all_power = np.zeros((N_MELS, TARGET_FRAMES), dtype=np.float32)
    hann = np.hanning(frame_length).astype(np.float32)

    for frame in range(TARGET_FRAMES):
        start = frame * HOP_LENGTH
        if start + frame_length > len(y):
            window = np.pad(y[start:], (0, start + frame_length - len(y)))
        else:
            window = y[start : start + frame_length]
        spectrum = np.abs(np.fft.rfft(window * hann)) ** 2
        all_power[:, frame] = np.maximum(filters @ spectrum.astype(np.float32), 1e-10)

    ref_db = 10 * np.log10(np.max(all_power))
    db = 10 * np.log10(np.maximum(all_power, 1e-10)) - ref_db
    return np.clip((db + 80) / 80, 0, 1).astype(np.float32)


def fix_frames(mel: np.ndarray) -> np.ndarray:
    if mel.shape[1] >= TARGET_FRAMES:
        return mel[:, :TARGET_FRAMES]
    return np.pad(mel, ((0, 0), (0, TARGET_FRAMES - mel.shape[1])))


def swift_like_mel_filters(fft_bins: int) -> np.ndarray:
    min_mel = hz_to_mel(FMIN)
    max_mel = hz_to_mel(FMAX)
    mel_points = np.linspace(min_mel, max_mel, N_MELS + 2)
    hz_points = mel_to_hz(mel_points)
    bin_points = np.clip(((N_FFT + 1) * hz_points / SAMPLE_RATE).astype(int), 0, fft_bins - 1)
    filters = np.zeros((N_MELS, fft_bins), dtype=np.float32)

    for mel in range(N_MELS):
        left = bin_points[mel]
        center = max(bin_points[mel + 1], left + 1)
        right = max(bin_points[mel + 2], center + 1)
        if left < center:
            for bin_idx in range(left, center):
                filters[mel, bin_idx] = (bin_idx - left) / (center - left)
        if center < right:
            for bin_idx in range(center, min(right, fft_bins)):
                filters[mel, bin_idx] = (right - bin_idx) / (right - center)
    return filters


def hz_to_mel(hz: np.ndarray | float) -> np.ndarray | float:
    return 2595 * np.log10(1 + np.asarray(hz) / 700)


def mel_to_hz(mel: np.ndarray | float) -> np.ndarray | float:
    return 700 * (np.power(10, np.asarray(mel) / 2595) - 1)


def predict(model: ct.models.MLModel, feature: np.ndarray) -> np.ndarray:
    x = feature[np.newaxis, np.newaxis, :, :].astype(np.float32)
    out = model.predict({"logmel": x})["var_80"].reshape(-1)
    if np.all((out >= 0) & (out <= 1)):
        return out
    exp = np.exp(out - np.max(out))
    return exp / np.sum(exp)


def compare(name: str, a: np.ndarray, b: np.ndarray) -> None:
    diff = np.abs(a - b)
    print(
        f"{name}: mae={diff.mean():.6f} max={diff.max():.6f} "
        f"corr={np.corrcoef(a.reshape(-1), b.reshape(-1))[0, 1]:.6f}"
    )


def main() -> None:
    model = ct.models.MLModel(str(MODEL_PATH))
    for label, path in load_examples():
        y = load_audio(path)
        reference = reference_logmel(y)
        current = swift_like_logmel(y)
        candidate = fixed_swift_candidate(y)

        print(f"\n{label}: {path}")
        compare("current_vs_reference", current, reference)
        compare("candidate_vs_reference", candidate, reference)
        print("reference_prob", predict(model, reference))
        print("current_prob  ", predict(model, current))
        print("candidate_prob", predict(model, candidate))


if __name__ == "__main__":
    main()
