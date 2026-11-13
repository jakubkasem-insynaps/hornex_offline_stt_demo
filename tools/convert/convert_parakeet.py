"""Export KInIT's Slovak Parakeet TDT 0.6b v3 (NeMo checkpoint) to sherpa-onnx, int8.

Runs the unmodified upstream exporter from k2-fsa/sherpa-onnx (pinned commit,
scripts/nemo/parakeet-tdt-0.6b-v3/export_onnx.py). That script loads
./parakeet-tdt-0.6b-v3.nemo when the file exists, so the KInIT checkpoint is
placed under that name. Quantization: onnxruntime quantize_dynamic, QUInt8 for
the encoder and QInt8 for decoder and joiner.

NeMo is only supported on Linux (use WSL2, a Linux machine or Colab). Needs
about 8 GB RAM and 6 GB disk.

Usage (from the repo root, in a venv with tools/convert/requirements-parakeet.txt):

    python tools/convert/convert_parakeet.py

Timebox: if this does not work within a day, use the catalog entry
"kinit-parakeet-tdt-v3-sk-thirdparty" (a ready-made third-party export of the
same checkpoint) and record the blocker in the README table.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import DEFAULT_OUT, fetch_upstream, model_spec, write_manifest  # noqa: E402

MODEL_ID = "kinit-parakeet-tdt-v3-sk"
NEMO_FILE = "parakeet-tdt-0.6b-v3-sk.nemo"


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p.add_argument("--work", type=Path, default=DEFAULT_OUT / "_work")
    args = p.parse_args()

    from huggingface_hub import hf_hub_download

    spec = model_spec(MODEL_ID)
    # Keep upstream's directory layout: export_onnx.py imports ../generate_bpe_vocab.py.
    base = args.work.resolve() / "upstream-nemo"
    script_dir = base / "parakeet-tdt-0.6b-v3"
    fetch_upstream("scripts/nemo/parakeet-tdt-0.6b-v3/export_onnx.py", script_dir / "export_onnx.py")
    fetch_upstream("scripts/nemo/generate_bpe_vocab.py", base / "generate_bpe_vocab.py")

    print(f"downloading {spec['sourceRepo']}@{spec['sourceRevision']} ({NEMO_FILE})")
    nemo = hf_hub_download(spec["sourceRepo"], NEMO_FILE, revision=spec["sourceRevision"], token=False)  # public repo
    shutil.copyfile(nemo, script_dir / "parakeet-tdt-0.6b-v3.nemo")

    subprocess.run([sys.executable, "export_onnx.py"], cwd=script_dir, check=True)

    out = args.out.resolve() / MODEL_ID
    out.mkdir(parents=True, exist_ok=True)
    files = {
        "encoder": "encoder.int8.onnx",
        "decoder": "decoder.int8.onnx",
        "joiner": "joiner.int8.onnx",
        "tokens": "tokens.txt",
    }
    for name in files.values():
        shutil.copyfile(script_dir / name, out / name)
    write_manifest(out, spec, files)
    print("Done. Start the proxy to serve models_out/ to the app, or run tools/eval/evaluate.py.")


if __name__ == "__main__":
    main()
