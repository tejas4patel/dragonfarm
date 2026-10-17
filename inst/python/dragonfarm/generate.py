"""Entry point: python -m dragonfarm.generate --request req.json --out out.json

Request: {"model": id_or_path, "adapter": path_or_null, "base_adapters": [paths], "prompts": [...],
          "system": str_or_null, "max_new_tokens": int, "temperature": float,
          "top_p": float, "trust_remote_code": bool}
"""

import argparse
import json
from pathlib import Path


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--request", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    with open(a.request, encoding="utf-8") as f:
        req = json.load(f)

    from .evaluate_utils import generate_reply
    from .hardware import resolve, wants_4bit
    from .loading import load_for_inference, load_tokenizer

    hw = resolve({"device": req.get("device", "auto"), "dtype": req.get("dtype", "auto")})
    trust = bool(req.get("trust_remote_code", False))
    four_bit = wants_4bit(req.get("load_in_4bit", "auto"), req["model"], hw.kind, hw.vram_gb)
    tok = load_tokenizer(req["model"], req.get("revision"), trust_remote_code=trust)
    model = load_for_inference(req["model"], hw, adapter=req.get("adapter"), revision=req.get("revision"),
                               trust_remote_code=trust, base_adapters=req.get("base_adapters") or [],
                               load_in_4bit=four_bit, allow_pickle=bool(req.get("allow_pickle", False)))

    outputs = []
    for prompt in req["prompts"]:
        messages = []
        if req.get("system"):
            messages.append({"role": "system", "content": req["system"]})
        messages.append({"role": "user", "content": prompt})
        outputs.append(generate_reply(
            model, tok, messages, hw.device,
            max_new_tokens=int(req.get("max_new_tokens", 256)),
            temperature=float(req.get("temperature", 0.7)),
            top_p=float(req.get("top_p", 0.9)),
        ))
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump({"outputs": outputs, "device": hw.device_str}, f, ensure_ascii=False)


if __name__ == "__main__":
    main()
