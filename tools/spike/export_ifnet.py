"""Export Practical-RIFE v4.26 IFNet (flow + mask heads, final compose warp excluded) to ONNX.

Inputs:  img0, img1  (1x3xHxW float32, 0..1), t (1x1x1x1 float32)
Outputs: flow (1x4xHxW: flow0->t xy, flow1->t xy, pixels), mask (1x1xHxW, sigmoid)
H and W must be multiples of 64 (5 blocks, scales 16..1, stride-4 encoder).
"""
import sys
from pathlib import Path

import torch
import torch.nn as nn

HERE = Path(__file__).resolve().parent
RIFE = HERE / "third_party" / "Practical-RIFE"
WEIGHTS = HERE / "third_party" / "rife_v4.26" / "train_log"
SCALE_LIST = [16, 8, 4, 2, 1]

for p in (RIFE, WEIGHTS):
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))


def load_ifnet() -> nn.Module:
    from IFNet_HDv3 import IFNet  # noqa: E402 (path injected above)

    net = IFNet()
    sd = torch.load(WEIGHTS / "flownet.pkl", map_location="cpu")
    sd = {k.replace("module.", ""): v for k, v in sd.items()}
    sd = {k: v for k, v in sd.items() if not k.startswith(("teacher.", "caltime."))}   # training-only heads, not in IFNet
    net.load_state_dict(sd, strict=True)
    return net.eval()


class FlowOnly(nn.Module):
    """IFNet forward minus the final warp/compose; mirrors IFNet.forward (fastmode) exactly."""

    def __init__(self, net, blocks: int = 5):
        super().__init__()
        self.net = net
        self.blocks = blocks   # run only the first N of the 5 coarse-to-fine blocks (scales 16, 8, 4, 2, 1)

    def forward(self, img0, img1, t):
        from model.warplayer import warp  # noqa: E402

        net = self.net
        timestep = t.expand(1, 1, img0.shape[2], img0.shape[3])
        f0 = net.encode(img0)
        f1 = net.encode(img1)
        blocks = [net.block0, net.block1, net.block2, net.block3, net.block4][: self.blocks]
        flow = mask = feat = None
        w0, w1 = img0, img1
        for i, blk in enumerate(blocks):
            if flow is None:
                flow, mask, feat = blk(torch.cat((img0, img1, f0, f1, timestep), 1), None, scale=SCALE_LIST[i])
            else:
                wf0 = warp(f0, flow[:, :2])
                wf1 = warp(f1, flow[:, 2:4])
                fd, mask, feat = blk(torch.cat((w0, w1, wf0, wf1, timestep, mask, feat), 1), flow, scale=SCALE_LIST[i])
                flow = flow + fd
            if i < len(blocks) - 1:  # inter-block image warps feed the next block; the final one is the compose warp (done on GPU)
                w0 = warp(img0, flow[:, :2])
                w1 = warp(img1, flow[:, 2:4])
        return flow, torch.sigmoid(mask)


def torch_flow(net, img0, img1, t: float):
    """Reference from the unmodified Practical-RIFE IFNet.forward (not FlowOnly): final flow and sigmoid mask."""
    with torch.no_grad():
        flow_list, mask_logits, _merged = net(torch.cat((img0, img1), 1), timestep=t, scale_list=SCALE_LIST)
        return flow_list[-1], torch.sigmoid(mask_logits)   # IFNet returns mask_list[4] before its own sigmoid


def export(res: tuple[int, int], out: Path, blocks: int = 5) -> Path:
    h, w = res
    assert h % 64 == 0 and w % 64 == 0, "H and W must be multiples of 64"
    assert 1 <= blocks <= 5
    m = FlowOnly(load_ifnet(), blocks)
    args = (torch.zeros(1, 3, h, w), torch.zeros(1, 3, h, w), torch.full((1, 1, 1, 1), 0.5))
    with torch.no_grad():
        torch.onnx.export(
            m, args, str(out), input_names=["img0", "img1", "t"], output_names=["flow", "mask"],
            opset_version=17, dynamo=False, do_constant_folding=True,
        )
    return Path(out)


if __name__ == "__main__":
    out_dir = HERE / "models"
    out_dir.mkdir(exist_ok=True)
    for name, res in (("ifnet_half", (576, 960)), ("ifnet_quarter", (320, 512))):
        p = export(res, out_dir / f"{name}.onnx")
        print(p, p.stat().st_size // 1024, "KB")
