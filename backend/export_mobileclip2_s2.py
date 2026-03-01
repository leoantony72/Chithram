"""
Export MobileCLIP2-S2 with eos_idx as a 3rd input.

Problem: ORT Mobile (used by Flutter onnxruntime package) doesn't include ArgMax
in its reduced operator set. MobileCLIP2-S2 uses ArgMax(13) to find the EOS token
position in the text sequence.

Fix: Implement text encoding manually, bypassing argmax. Accept eos_idx [1] as a
precomputed int64 input, set by the Dart tokenizer (position of token 49407 in
the tokenized sequence).

Inputs:
  image:   float32 [1, 3, 256, 256]   pixel/255, NO normalization
  text:    int64   [1, 77]             CLIP tokenized, padded to 77
  eos_idx: int64   [1]                 index of EOS token (49407) in text[0]

Outputs:
  output_0: float32 [1, 512]          L2-normalized image embedding
  output_1: float32 [1, 512]          L2-normalized text  embedding
"""

import torch
import torch.nn as nn
import open_clip
import onnx
import onnxruntime as ort
import numpy as np

print("Loading MobileCLIP2-S2 ...")
clip, _, _ = open_clip.create_model_and_transforms("MobileCLIP-S2", pretrained="datacompdr")
clip.eval()
tm = clip.text  # TextTransformer

IMAGE_SIZE = 256
EOS_TOKEN_ID = 49407  # Standard CLIP EOS token


class DualEncoderNoArgmax(nn.Module):
    def __init__(self, clip_model, text_module):
        super().__init__()
        self.clip = clip_model
        self.tm = text_module

    def forward(self, image: torch.Tensor, text: torch.Tensor, eos_idx: torch.Tensor):
        # ── Image branch ────────────────────────────────────────────────────
        image_features = self.clip.encode_image(image)

        # ── Text branch (manual — no argmax) ─────────────────────────────
        x, attn_mask = self.tm._embeds(text)
        x = self.tm.transformer(x, attn_mask=attn_mask)
        x = self.tm.ln_final(x)
        # Index with eos_idx instead of argmax
        # eos_idx shape: [1]   → x[:, eos_idx[0], :] picks one token per batch
        pooled = x[0, eos_idx[0], :]  # [D]
        pooled = pooled.unsqueeze(0)   # [1, D]
        pooled = pooled @ self.tm.text_projection  # text_projection is a Parameter (D×D)

        # ── L2 normalize ──────────────────────────────────────────────────
        image_features = image_features / image_features.norm(dim=-1, keepdim=True)
        pooled = pooled / pooled.norm(dim=-1, keepdim=True)

        return image_features, pooled


encoder = DualEncoderNoArgmax(clip, tm)
encoder.eval()

# Dummy inputs
dummy_image = torch.zeros(1, 3, IMAGE_SIZE, IMAGE_SIZE, dtype=torch.float32)
dummy_text  = torch.zeros(1, 77, dtype=torch.int64)
# EOS token at position 1 (after BOS) for dummy — 0-indexed
dummy_eos   = torch.tensor([1], dtype=torch.int64)

with torch.no_grad():
    img_emb, txt_emb = encoder(dummy_image, dummy_text, dummy_eos)
print(f"PyTorch smoke-test: image={img_emb.shape}, text={txt_emb.shape}")

# ── Export ───────────────────────────────────────────────────────────────────
out_path = "./models/semantic-search.onnx"
print(f"Exporting with legacy API (opset 13) → {out_path} ...")

with torch.no_grad():
    torch.onnx.export(
        encoder,
        (dummy_image, dummy_text, dummy_eos),
        out_path,
        input_names=["image", "text", "eos_idx"],
        output_names=["output_0", "output_1"],
        dynamic_axes={
            "image":    {0: "batch"},
            "text":     {0: "batch"},
            "output_0": {0: "batch"},
            "output_1": {0: "batch"},
        },
        opset_version=13,
        do_constant_folding=True,
        dynamo=False,
    )
print("Export done.")

# ── Fix IR version ────────────────────────────────────────────────────────────
mp = onnx.load(out_path)
print(f"IR version: {mp.ir_version}, opset: {mp.opset_import[0].version}")
if mp.ir_version > 9:
    mp.ir_version = 9
    onnx.save(mp, out_path)
    print("Forced IR version to 9.")

# ── Verify ────────────────────────────────────────────────────────────────────
print("Verifying with ONNXRuntime ...")
sess = ort.InferenceSession(out_path, providers=["CPUExecutionProvider"])
r = sess.run(None, {
    "image":   dummy_image.numpy(),
    "text":    dummy_text.numpy(),
    "eos_idx": dummy_eos.numpy(),
})
img_n = np.linalg.norm(r[0][0])
txt_n = np.linalg.norm(r[1][0])
print(f"ORT OK: shapes={r[0].shape},{r[1].shape}  norms={img_n:.4f}/{txt_n:.4f}")
print("\nDone. Run: python update_model_version.py")
