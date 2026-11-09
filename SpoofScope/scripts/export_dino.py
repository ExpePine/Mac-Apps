"""Export DINOv2-small (Apache-2.0, facebook/dinov2-small) to ONNX at 560x560 input. Runs in CI on Linux."""
import sys, numpy as np, torch
from transformers import AutoModel

out = sys.argv[1] if len(sys.argv) > 1 else "models/dinov2_small_560.onnx"
m = AutoModel.from_pretrained("facebook/dinov2-small", attn_implementation="eager").eval()


class Wrap(torch.nn.Module):
    def __init__(self, m):
        super().__init__(); self.m = m

    def forward(self, x):
        return self.m(pixel_values=x).last_hidden_state


w = Wrap(m).eval()
x = torch.randn(1, 3, 560, 560)
kw = dict(input_names=["pixel_values"], output_names=["tokens"], opset_version=17)
try:
    torch.onnx.export(w, x, out, dynamo=False, **kw)
except TypeError:
    torch.onnx.export(w, x, out, **kw)

import onnxruntime as ort
ref = w(x).detach().numpy()
got = ort.InferenceSession(out, providers=["CPUExecutionProvider"]).run(None, {"pixel_values": x.numpy()})[0]
err = float(np.abs(ref - got).max())
print("onnx output", got.shape, "max abs diff vs torch", err)
assert got.shape == (1, 1601, 384) and err < 1e-2, (got.shape, err)
