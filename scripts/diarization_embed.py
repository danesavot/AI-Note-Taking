#!/usr/bin/env python3
"""Long-running speaker-embedding service for the Meeting Assistant.

Loads a SpeechBrain ECAPA-TDNN speaker encoder once, then answers embedding
requests over stdin/stdout using a simple line-delimited JSON protocol. This
keeps the (slow) model load out of the per-utterance hot path.

Protocol
--------
Request  (one JSON object per line on stdin):
    {"id": <int>, "path": "/tmp/utt.f32", "sr": 16000}
  where `path` points to a file of raw little-endian float32 mono PCM samples.

Response (one JSON object per line on stdout):
    {"id": <int>, "embedding": [<float>, ...]}      # success
    {"id": <int>, "error": "<message>"}             # failure

A single line `{"ready": true, "dim": <int>}` is emitted once the model is
loaded and the service is ready to accept requests.
"""

import json
import os
import sys


def log(message: str) -> None:
    print(f"[embed_service] {message}", file=sys.stderr, flush=True)


def main() -> int:
    # Keep everything CPU + single-threaded; embeddings are tiny and this avoids
    # thread-pool contention with the host app.
    os.environ.setdefault("OMP_NUM_THREADS", "1")

    try:
        import numpy as np
        import torch
        from speechbrain.inference.speaker import EncoderClassifier
    except Exception as exc:  # pragma: no cover - import failure path
        print(json.dumps({"ready": False, "error": f"import failed: {exc}"}), flush=True)
        return 1

    torch.set_num_threads(1)

    savedir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "models", "ecapa")
    savedir = os.path.abspath(savedir)
    os.makedirs(savedir, exist_ok=True)

    try:
        log("loading ECAPA-TDNN speaker encoder...")
        classifier = EncoderClassifier.from_hparams(
            source="speechbrain/spkrec-ecapa-voxceleb",
            savedir=savedir,
            run_opts={"device": "cpu"},
        )
        log("model loaded")
    except Exception as exc:
        print(json.dumps({"ready": False, "error": f"model load failed: {exc}"}), flush=True)
        return 1

    def embed(path: str) -> list:
        samples = np.fromfile(path, dtype="<f4")
        if samples.size == 0:
            raise ValueError("empty audio")
        wav = torch.from_numpy(samples).float().unsqueeze(0)  # [1, time]
        with torch.no_grad():
            emb = classifier.encode_batch(wav)  # [1, 1, dim]
        vector = emb.squeeze().cpu().numpy().astype("float32")
        # L2-normalize so the host can use plain dot-product as cosine similarity.
        norm = float(np.linalg.norm(vector))
        if norm > 0:
            vector = vector / norm
        return vector.tolist()

    # Probe embedding dimension with a short silent buffer.
    try:
        import numpy as _np
        probe = torch.zeros(1, 16000)
        with torch.no_grad():
            dim = int(classifier.encode_batch(probe).squeeze().shape[-1])
    except Exception:
        dim = 192

    print(json.dumps({"ready": True, "dim": dim}), flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            print(json.dumps({"error": f"bad json: {exc}"}), flush=True)
            continue

        req_id = request.get("id")
        path = request.get("path")
        if request.get("command") == "shutdown":
            break
        if not path:
            print(json.dumps({"id": req_id, "error": "missing path"}), flush=True)
            continue

        try:
            vector = embed(path)
            print(json.dumps({"id": req_id, "embedding": vector}), flush=True)
        except Exception as exc:
            print(json.dumps({"id": req_id, "error": str(exc)}), flush=True)
        finally:
            # The host owns the temp file lifecycle, but clean up best-effort.
            try:
                if path and os.path.exists(path):
                    os.remove(path)
            except OSError:
                pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
