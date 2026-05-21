from __future__ import annotations

import csv
import subprocess
import zipfile
from pathlib import Path
from urllib.request import urlretrieve


ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data"
ARCHIVE = DATA_DIR / "esc50.zip"
ESC50_DIR = DATA_DIR / "ESC-50-master"
URL = "https://github.com/karolpiczak/ESC-50/archive/refs/heads/master.zip"


def main() -> None:
    DATA_DIR.mkdir(exist_ok=True)

    if not ARCHIVE.exists():
        print(f"Downloading ESC-50 to {ARCHIVE}")
        urlretrieve(URL, ARCHIVE)

    if not ESC50_DIR.exists():
        print(f"Extracting {ARCHIVE}")
        with zipfile.ZipFile(ARCHIVE) as zf:
            zf.extractall(DATA_DIR)

    metadata = ESC50_DIR / "meta" / "esc50.csv"
    audio_dir = ESC50_DIR / "audio"
    if not metadata.exists() or not audio_dir.exists():
        raise FileNotFoundError("ESC-50 metadata/audio not found after extraction")

    with metadata.open(newline="") as f:
        rows = list(csv.DictReader(f))

    snore = [r for r in rows if r["category"] == "snoring"]
    non_snore = [r for r in rows if r["category"] != "snoring"]
    print(f"ESC-50 ready: {len(snore)} snoring clips, {len(non_snore)} non-snore clips")

    # Make a tiny manifest for quick inspection and reproducible training.
    manifest = DATA_DIR / "esc50_snore_manifest.csv"
    with manifest.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["path", "label", "category", "fold"])
        writer.writeheader()
        for row in rows:
            label = "snore" if row["category"] == "snoring" else "non_snore"
            writer.writerow(
                {
                    "path": str(audio_dir / row["filename"]),
                    "label": label,
                    "category": row["category"],
                    "fold": row["fold"],
                }
            )

    print(f"Wrote {manifest}")

    try:
        subprocess.run(["du", "-sh", str(ESC50_DIR)], check=False)
    except Exception:
        pass


if __name__ == "__main__":
    main()
