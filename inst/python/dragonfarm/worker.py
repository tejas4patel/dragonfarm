"""Persistent inference worker: python -m dragonfarm.worker

Reads one JSON request per line on stdin and writes one JSON response per
line on stdout, keeping loaded models in memory between requests. R talks
to it through a pipe, so a session pays the model load once instead of
once per call.

Requests:
  {"op": "ping"}
  {"op": "generate", "model": id_or_path, "adapter": path_or_null,
   "base_adapters": [paths], "trust_remote_code": bool,
   "conversations": [[{"role": ..., "content": ...}, ...], ...],
   "max_new_tokens": int, "temperature": float, "top_p": float,
   "stream": bool}
  {"op": "unload"}          drop cached models
  {"op": "quit"}

Responses:
  {"ok": true, "outputs": [...], "device": "cuda:0"}      (generate)
  {"ok": true, "token": "..."}  ... {"ok": true, "done": true, "output": "..."}   (streaming, one conversation)
  {"ok": false, "error": "...", "code": "MODEL_NOT_FOUND" | "OUT_OF_MEMORY" | ... (see errors.py)}

A request may carry "id"; every response line written for it then carries
the same "id".
"""

import json
import sys
import threading
import traceback
from collections import OrderedDict

from .errors import describe


# The id of the request being served. Every line written for it carries the
# id, so R can drop a late reply to a request it stopped waiting for (a
# timeout, an interrupt) instead of taking it as the answer to the next one.
_current_id = None


def emit(obj):
    if _current_id is not None and "id" not in obj:
        obj = {**obj, "id": _current_id}
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


class ModelCache:
    """Keep the most recently used models loaded (default: two)."""

    def __init__(self, capacity=2):
        self.capacity = capacity
        self.items = OrderedDict()
        self.hw = None

    def key(self, req, four_bit=False):
        return json.dumps([req["model"], req.get("adapter"), req.get("base_adapters") or [],
                           bool(req.get("trust_remote_code", False)), bool(four_bit)])

    def get(self, req):
        from .hardware import resolve, wants_4bit
        from .loading import load_for_inference, load_tokenizer

        if self.hw is None:
            self.hw = resolve({"device": req.get("device", "auto"), "dtype": req.get("dtype", "auto")})
        four_bit = wants_4bit(req.get("load_in_4bit", "auto"), req["model"], self.hw.kind, self.hw.vram_gb)
        k = self.key(req, four_bit)
        if k in self.items:
            self.items.move_to_end(k)
            return self.items[k]
        while len(self.items) >= self.capacity:
            _, (old_tok, old_model) = self.items.popitem(last=False)
            del old_tok, old_model
            try:
                import torch

                if torch.cuda.is_available():
                    torch.cuda.empty_cache()
            except Exception:
                pass
        trust = bool(req.get("trust_remote_code", False))
        if four_bit:
            print(f"[dragonfarm] loading {req['model']} in 4-bit (NF4)", file=sys.stderr, flush=True)
        tok = load_tokenizer(req["model"], trust_remote_code=trust)
        model = load_for_inference(req["model"], self.hw, adapter=req.get("adapter"), trust_remote_code=trust,
                                   base_adapters=req.get("base_adapters") or [], load_in_4bit=four_bit)
        self.items[k] = (tok, model)
        return tok, model

    def clear(self):
        self.items.clear()
        try:
            import torch

            if torch.cuda.is_available():
                torch.cuda.empty_cache()
        except Exception:
            pass


def generate_all(tok, model, hw, req):
    from .evaluate_utils import generate_replies

    return generate_replies(
        model, tok, req["conversations"], hw.device,
        max_new_tokens=int(req.get("max_new_tokens", 256)),
        temperature=float(req.get("temperature", 0.7)),
        top_p=float(req.get("top_p", 0.9)),
        batch_size=int(req.get("batch_size", 8)),
        tools=req.get("tools"),
    )


def generate_stream(tok, model, hw, req):
    """Stream tokens for the first conversation; returns the full text."""
    import torch
    from transformers import TextIteratorStreamer

    from .data import render_prompt

    messages = req["conversations"][0]
    text = render_prompt(tok, messages, req.get("tools"))
    enc = tok(text, return_tensors="pt", add_special_tokens=False).to(hw.device)
    streamer = TextIteratorStreamer(tok, skip_prompt=True, skip_special_tokens=True)
    kwargs = dict(**enc, streamer=streamer, max_new_tokens=int(req.get("max_new_tokens", 256)),
                  pad_token_id=tok.pad_token_id)
    temperature = float(req.get("temperature", 0.7))
    if temperature > 0:
        kwargs.update(do_sample=True, temperature=temperature, top_p=float(req.get("top_p", 0.9)))
    else:
        kwargs.update(do_sample=False)

    def run():
        with torch.no_grad():
            model.generate(**kwargs)

    thread = threading.Thread(target=run)
    thread.start()
    pieces = []
    for piece in streamer:
        if piece:
            pieces.append(piece)
            emit({"ok": True, "token": piece})
    thread.join()
    return "".join(pieces).strip()


def main():
    global _current_id
    cache = ModelCache()
    retriever = None   # created on first use; holds the small embedding model and loaded indexes
    emit({"ok": True, "ready": True})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        _current_id = None
        try:
            req = json.loads(line)
            _current_id = req.get("id")
            op = req.get("op")
            if op == "ping":
                emit({"ok": True, "pong": True, "loaded": len(cache.items)})
            elif op == "unload":
                cache.clear()
                retriever = None
                emit({"ok": True, "loaded": 0})
            elif op in ("index", "retrieve"):
                from .retrieval import DEFAULT_MODEL, Retriever

                retriever = retriever or Retriever()
                if op == "index":
                    info = retriever.index(req["dir"], req.get("model") or DEFAULT_MODEL, bool(req.get("force")))
                    emit({"ok": True, "index": info})
                else:
                    hits = retriever.retrieve(req["dir"], req["queries"], k=int(req.get("k", 4)),
                                              mode=req.get("method") or "hybrid", extra=int(req.get("extra") or 0))
                    emit({"ok": True, "hits": hits})
            elif op == "quit":
                emit({"ok": True, "bye": True})
                break
            elif op == "generate":
                tok, model = cache.get(req)
                if req.get("stream"):
                    output = generate_stream(tok, model, cache.hw, req)
                    emit({"ok": True, "done": True, "output": output, "device": cache.hw.device_str})
                else:
                    outputs = generate_all(tok, model, cache.hw, req)
                    emit({"ok": True, "outputs": outputs, "device": cache.hw.device_str})
            else:
                emit({"ok": False, "error": f"unknown op {op!r}", "code": "UNKNOWN"})
        except Exception as e:  # noqa: BLE001 - report and keep serving
            emit({"ok": False, **describe(e), "traceback": traceback.format_exc()[-2000:]})


if __name__ == "__main__":
    main()
