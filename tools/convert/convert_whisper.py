"""Convert a Hugging Face Whisper fine-tune to sherpa-onnx format, int8-quantized.

sherpa-onnx's own exporter (scripts/whisper/export-onnx.py) only knows the
stock OpenAI checkpoints. This script:

  1. downloads the fine-tune from Hugging Face (pinned revision from the catalog),
  2. renames its weights into an openai-whisper model and checks the result
     against the Hugging Face model on random input,
  3. runs the unmodified upstream exporter (pinned commit) on that model, which
     writes ONNX files and int8 versions (onnxruntime quantize_dynamic, MatMul
     weights only, QInt8),
  4. copies the int8 files to models_out/<id>/ and writes manifest.json.

Usage (from the repo root, in a venv with tools/convert/requirements-whisper.txt):

    python tools/convert/convert_whisper.py kinit-whisper-small-sk
    python tools/convert/convert_whisper.py --all

The model ids are the `hosting: self`, `family: whisper` entries of
app/assets/models.json.
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import DEFAULT_OUT, fetch_upstream, load_catalog, model_spec, write_manifest  # noqa: E402

# (Hugging Face name fragment, openai-whisper name fragment). Order matters.
_RENAMES = [
    (".layers.", ".blocks."),
    (".self_attn.q_proj.", ".attn.query."),
    (".self_attn.k_proj.", ".attn.key."),
    (".self_attn.v_proj.", ".attn.value."),
    (".self_attn.out_proj.", ".attn.out."),
    (".self_attn_layer_norm.", ".attn_ln."),
    (".encoder_attn.q_proj.", ".cross_attn.query."),
    (".encoder_attn.k_proj.", ".cross_attn.key."),
    (".encoder_attn.v_proj.", ".cross_attn.value."),
    (".encoder_attn.out_proj.", ".cross_attn.out."),
    (".encoder_attn_layer_norm.", ".cross_attn_ln."),
    (".fc1.", ".mlp.0."),
    (".fc2.", ".mlp.2."),
    (".final_layer_norm.", ".mlp_ln."),
    ("encoder.layer_norm.", "encoder.ln_post."),
    ("decoder.layer_norm.", "decoder.ln."),
    ("decoder.embed_tokens.", "decoder.token_embedding."),
]


def hf_to_openai_state_dict(hf_state: dict) -> dict:
    out = {}
    for key, value in hf_state.items():
        if key == "proj_out.weight":
            continue  # tied to the token embedding in openai-whisper
        k = key[len("model."):] if key.startswith("model.") else key
        if k == "encoder.embed_positions.weight":
            k = "encoder.positional_embedding"
        elif k == "decoder.embed_positions.weight":
            k = "decoder.positional_embedding"
        else:
            for a, b in _RENAMES:
                k = k.replace(a, b)
        out[k] = value
    return out


def build_openai_model(repo: str, revision: str | None):
    import torch
    import whisper
    from transformers import WhisperForConditionalGeneration

    print(f"loading {repo}@{revision or 'main'} from Hugging Face")
    # token=False: these repos are public; an expired cached login would otherwise
    # make the Hub answer 401.
    hf = WhisperForConditionalGeneration.from_pretrained(repo, revision=revision, token=False).eval()
    c = hf.config
    dims = whisper.model.ModelDimensions(
        n_mels=c.num_mel_bins,
        n_audio_ctx=c.max_source_positions,
        n_audio_state=c.d_model,
        n_audio_head=c.encoder_attention_heads,
        n_audio_layer=c.encoder_layers,
        n_vocab=c.vocab_size,
        n_text_ctx=c.max_target_positions,
        n_text_state=c.d_model,
        n_text_head=c.decoder_attention_heads,
        n_text_layer=c.decoder_layers,
    )
    model = whisper.model.Whisper(dims)
    # strict=True: any weight that was not renamed correctly is an error.
    model.load_state_dict(hf_to_openai_state_dict(hf.state_dict()), strict=True)
    model.eval()

    # The two implementations must produce the same logits.
    torch.manual_seed(0)
    mel = torch.randn(1, dims.n_mels, 3000)
    tokens = torch.tensor([[c.decoder_start_token_id, 50258, 50359]])
    with torch.no_grad():
        ours = model(mel, tokens)
        theirs = hf(input_features=mel, decoder_input_ids=tokens).logits
    diff = (ours - theirs).abs().max().item()
    print(f"max |logit difference| vs Hugging Face model: {diff:.2e}")
    if diff > 1e-2:
        raise SystemExit("Converted weights do not reproduce the Hugging Face model; aborting.")
    return model


def export(spec: dict, out_root: Path, work_root: Path) -> None:
    import torch
    from whisper.model import disable_sdpa

    size = spec["whisperSize"]  # tiny | base | small | medium: a name the upstream exporter accepts
    model = build_openai_model(spec["sourceRepo"], spec.get("sourceRevision"))

    work = work_root / spec["id"]
    work.mkdir(parents=True, exist_ok=True)
    script = fetch_upstream("scripts/whisper/export-onnx.py", work_root / "upstream" / "export_whisper_onnx.py")
    module_spec = importlib.util.spec_from_file_location("export_whisper_onnx", script)
    upstream = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(upstream)
    # Hand the exporter our fine-tuned weights instead of the stock checkpoint.
    upstream.load_model = lambda name: model

    argv, cwd = sys.argv, os.getcwd()
    sys.argv = ["export-onnx.py", "--model", size]
    os.chdir(work)
    try:
        torch.set_num_threads(1)
        try:
            torch.set_num_interop_threads(1)
        except RuntimeError:
            pass  # can only be set once per process; already done for an earlier model
        with disable_sdpa():
            upstream.main()
    finally:
        sys.argv = argv
        os.chdir(cwd)

    out = out_root / spec["id"]
    out.mkdir(parents=True, exist_ok=True)
    files = {"encoder": "encoder.int8.onnx", "decoder": "decoder.int8.onnx", "tokens": "tokens.txt"}
    shutil.copyfile(work / f"{size}-encoder.int8.onnx", out / files["encoder"])
    shutil.copyfile(work / f"{size}-decoder.int8.onnx", out / files["decoder"])
    shutil.copyfile(work / f"{size}-tokens.txt", out / files["tokens"])
    write_manifest(out, spec, files, {"opset": 17, "fp32SizeBytes": sum(
        (work / f"{size}-{part}.onnx").stat().st_size for part in ("encoder", "decoder"))})


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("model_ids", nargs="*", help="catalog ids, e.g. kinit-whisper-small-sk")
    p.add_argument("--all", action="store_true", help="convert every self-hosted Whisper model in the catalog")
    p.add_argument("--out", type=Path, default=DEFAULT_OUT, help="output root (default: models_out/)")
    p.add_argument("--work", type=Path, default=DEFAULT_OUT / "_work", help="scratch directory for fp32 ONNX files")
    args = p.parse_args()

    ids = list(args.model_ids)
    if args.all:
        ids = [m["id"] for m in load_catalog()["models"] if m["family"] == "whisper" and m["hosting"] == "self"]
    if not ids:
        p.error("give at least one model id or --all")
    for model_id in ids:
        spec = model_spec(model_id)
        if spec["family"] != "whisper" or spec["hosting"] != "self":
            raise SystemExit(f"{model_id} is not a self-converted Whisper model")
        print(f"\n=== {model_id} ===")
        export(spec, args.out.resolve(), args.work.resolve())
    print("\nDone. Start the proxy to serve models_out/ to the app, or run tools/eval/evaluate.py.")


if __name__ == "__main__":
    main()
