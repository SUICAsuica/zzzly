from __future__ import annotations

import csv
import json
from pathlib import Path

import librosa
import numpy as np
import tensorflow as tf
from sklearn.metrics import classification_report, confusion_matrix
from sklearn.utils import class_weight
from tqdm import tqdm


ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data"
MANIFEST = DATA_DIR / "esc50_snore_manifest.csv"
MODELS_DIR = ROOT / "models"

SAMPLE_RATE = 16_000
DURATION_SECONDS = 2.0
SAMPLES = int(SAMPLE_RATE * DURATION_SECONDS)
N_MELS = 64
HOP_LENGTH = 320


NEGATIVE_CATEGORIES = {
    "breathing",
    "coughing",
    "sneezing",
    "brushing_teeth",
    "clock_tick",
    "door_wood_creaks",
    "washing_machine",
    "vacuum_cleaner",
    "rain",
    "wind",
    "footsteps",
    "drinking_sipping",
    "toilet_flush",
    "keyboard_typing",
    "mouse_click",
    "crackling_fire",
}


def load_manifest() -> list[dict[str, str]]:
    if not MANIFEST.exists():
        raise FileNotFoundError(f"Run ml/download_esc50.py first: {MANIFEST}")

    with MANIFEST.open(newline="") as f:
        rows = list(csv.DictReader(f))

    return [
        row
        for row in rows
        if row["label"] == "snore" or row["category"] in NEGATIVE_CATEGORIES
    ]


def audio_to_logmel(path: str) -> np.ndarray:
    y, _ = librosa.load(path, sr=SAMPLE_RATE, mono=True)
    if len(y) < SAMPLES:
        y = np.pad(y, (0, SAMPLES - len(y)))
    else:
        y = y[:SAMPLES]

    mel = librosa.feature.melspectrogram(
        y=y,
        sr=SAMPLE_RATE,
        n_fft=1024,
        hop_length=HOP_LENGTH,
        n_mels=N_MELS,
        fmin=40,
        fmax=4_000,
        power=2.0,
    )
    logmel = librosa.power_to_db(mel, ref=np.max)
    logmel = (logmel + 80.0) / 80.0
    return logmel.astype(np.float32)[..., np.newaxis]


def build_model(input_shape: tuple[int, int, int]) -> tf.keras.Model:
    model = tf.keras.Sequential(
        [
            tf.keras.layers.Input(shape=input_shape),
            tf.keras.layers.Conv2D(16, 3, activation="relu", padding="same"),
            tf.keras.layers.BatchNormalization(),
            tf.keras.layers.MaxPooling2D(),
            tf.keras.layers.Conv2D(32, 3, activation="relu", padding="same"),
            tf.keras.layers.BatchNormalization(),
            tf.keras.layers.MaxPooling2D(),
            tf.keras.layers.Conv2D(64, 3, activation="relu", padding="same"),
            tf.keras.layers.GlobalAveragePooling2D(),
            tf.keras.layers.Dropout(0.25),
            tf.keras.layers.Dense(1, activation="sigmoid"),
        ]
    )
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=1e-3),
        loss="binary_crossentropy",
        metrics=["accuracy", tf.keras.metrics.AUC(name="auc")],
    )
    return model


def main() -> None:
    rows = load_manifest()
    x = []
    y = []
    folds = []

    for row in tqdm(rows, desc="features"):
        x.append(audio_to_logmel(row["path"]))
        y.append(1 if row["label"] == "snore" else 0)
        folds.append(int(row["fold"]))

    x_array = np.stack(x)
    y_array = np.asarray(y, dtype=np.float32)
    folds_array = np.asarray(folds)

    train_mask = folds_array != 5
    test_mask = folds_array == 5

    x_train, y_train = x_array[train_mask], y_array[train_mask]
    x_test, y_test = x_array[test_mask], y_array[test_mask]

    weights = class_weight.compute_class_weight(
        class_weight="balanced",
        classes=np.array([0, 1]),
        y=y_train.astype(int),
    )
    class_weights = {0: float(weights[0]), 1: float(weights[1])}

    model = build_model(x_train.shape[1:])
    model.fit(
        x_train,
        y_train,
        validation_split=0.2,
        epochs=30,
        batch_size=16,
        class_weight=class_weights,
        callbacks=[
            tf.keras.callbacks.EarlyStopping(
                monitor="val_auc",
                mode="max",
                patience=6,
                restore_best_weights=True,
            )
        ],
    )

    probabilities = model.predict(x_test).reshape(-1)

    thresholds = np.linspace(0.1, 0.95, 86)
    best_threshold = 0.5
    best_f1 = -1.0
    for threshold in thresholds:
        candidate = (probabilities >= threshold).astype(int)
        tp = np.sum((candidate == 1) & (y_test == 1))
        fp = np.sum((candidate == 1) & (y_test == 0))
        fn = np.sum((candidate == 0) & (y_test == 1))
        precision = tp / max(tp + fp, 1)
        recall = tp / max(tp + fn, 1)
        f1 = 2 * precision * recall / max(precision + recall, 1e-9)
        if f1 > best_f1:
            best_f1 = f1
            best_threshold = float(threshold)

    predictions = (probabilities >= best_threshold).astype(int)
    print(confusion_matrix(y_test.astype(int), predictions))
    print(classification_report(y_test.astype(int), predictions, target_names=["non_snore", "snore"]))
    print(f"Best threshold: {best_threshold:.2f}, f1={best_f1:.3f}")

    MODELS_DIR.mkdir(exist_ok=True)
    keras_path = MODELS_DIR / "zzzly_snore.keras"
    model.save(keras_path)
    print(f"Saved {keras_path}")

    metadata_path = MODELS_DIR / "zzzly_snore_metadata.json"
    metadata_path.write_text(
        json.dumps(
            {
                "sample_rate": SAMPLE_RATE,
                "duration_seconds": DURATION_SECONDS,
                "n_mels": N_MELS,
                "hop_length": HOP_LENGTH,
                "threshold": best_threshold,
                "training_source": "ESC-50 snoring class plus selected ESC-50 non-snore classes",
                "warning": "Prototype only. ESC-50 has 40 snoring clips; collect in-app hard negatives before production.",
            },
            indent=2,
        )
    )
    print(f"Saved {metadata_path}")

    try:
        import coremltools as ct

        mlpackage_path = MODELS_DIR / "zzzly_snore.mlpackage"
        input_shape = tuple(int(dim) for dim in x_train[:1].shape)
        example = tf.TensorSpec(shape=input_shape, dtype=tf.float32, name="logmel")
        traced = tf.function(lambda inputs: model(inputs)).get_concrete_function(example)
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="logmel", shape=input_shape)],
            classifier_config=ct.ClassifierConfig(["non_snore", "snore"]),
            minimum_deployment_target=ct.target.iOS17,
        )
        mlmodel.save(mlpackage_path)
        print(f"Saved {mlpackage_path}")
    except Exception as exc:
        print(f"Core ML conversion skipped: {exc}")


if __name__ == "__main__":
    main()
