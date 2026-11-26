#!/usr/bin/env python3
"""
Reproducible local evaluation script for og Docs Phase 2 (Issue #21, V-7).

Extracts the embedded `og_docs_server.py` from `Sources/OgCore/Docs/DocsModelServerCommand.swift`,
starts it on `127.0.0.1:<free port>` via `uvx` (Apple Silicon MLX), and evaluates golden queries
against either a user-supplied chunk JSON file (`--chunks`) or a built-in Go stdlib sample.

Usage:
    python3 scripts/eval-docs-phase2.py
    python3 scripts/eval-docs-phase2.py --offline
    python3 scripts/eval-docs-phase2.py --chunks /path/to/goroot-chunks.json --offline
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path


DEFAULT_EMBED_MODEL = "mlx-community/bge-m3-mlx-8bit"
DEFAULT_RERANK_MODEL = "caslca/bge-reranker-v2-m3-mlx-8bit"

SAMPLE_CHUNKS = [
    {
        "stable_id": "stdlib:encoding/json:Unmarshal",
        "title": "encoding/json.Unmarshal",
        "text": "encoding/json.Unmarshal\nUnmarshal parses the JSON-encoded data and stores the result in the value pointed to by v.\nfunc Unmarshal(data []byte, v any) error",
    },
    {
        "stable_id": "stdlib:encoding/json:Decoder",
        "title": "encoding/json.Decoder",
        "text": "encoding/json.Decoder\nA Decoder reads and decodes JSON values from an input stream.\ntype Decoder struct",
    },
    {
        "stable_id": "stdlib:encoding/json:Encoder",
        "title": "encoding/json.Encoder",
        "text": "encoding/json.Encoder\nAn Encoder writes JSON values to an output stream. Call SetIndent to indent output.\ntype Encoder struct",
    },
    {
        "stable_id": "stdlib:encoding/json:MarshalIndent",
        "title": "encoding/json.MarshalIndent",
        "text": "encoding/json.MarshalIndent\nMarshalIndent is like Marshal but applies Indent to format the output.\nfunc MarshalIndent(v any, prefix, indent string) ([]byte, error)",
    },
    {
        "stable_id": "stdlib:bufio:Scanner",
        "title": "bufio.Scanner",
        "text": "bufio.Scanner\nScanner provides a convenient interface for reading data such as a file of newline-delimited lines of text.\ntype Scanner struct",
    },
    {
        "stable_id": "stdlib:context:WithTimeout",
        "title": "context.WithTimeout",
        "text": "context.WithTimeout\nWithTimeout returns WithDeadline(parent, time.Now().Add(timeout)).\nfunc WithTimeout(parent Context, timeout time.Duration) (Context, CancelFunc)",
    },
    {
        "stable_id": "stdlib:regexp:Compile",
        "title": "regexp.Compile",
        "text": "regexp.Compile\nCompile parses a regular expression and returns, if successful, a Regexp object that can be used to match against text.\nfunc Compile(expr string) (*Regexp, error)",
    },
    {
        "stable_id": "stdlib:slices:Compact",
        "title": "slices.Compact",
        "text": "slices.Compact\nCompact replaces consecutive runs of equal elements with a single copy.\nfunc Compact[S ~[]E, E comparable](s S) S",
    },
]

GOLDEN_QUERIES = [
    ("json のデコード", ["Unmarshal", "Decoder"]),
    ("ファイルを1行ずつ読みたい", ["Scanner"]),
    ("JSON を整形して出したい", ["MarshalIndent", "Encoder"]),
    ("処理にタイムアウトを付けたい", ["WithTimeout"]),
    ("標準ライブラリに正規表現ある？", ["Compile"]),
    ("重複を取り除きたい", ["Compact"]),
    ("標準ライブラリに量子テレポーテーション制御ある？", []),
]


def free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def extract_embedded_server(repo_root: Path, dest: Path) -> None:
    swift_path = repo_root / "Sources/OgCore/Docs/DocsModelServerCommand.swift"
    src = swift_path.read_text(encoding="utf-8")
    match = re.search(r'embeddedMLXServerScript:\s*String\s*=\s*#"""\n(.*?)\n"""#', src, re.DOTALL)
    if not match:
        raise RuntimeError(f"Could not locate embeddedMLXServerScript in {swift_path}")
    dest.write_text(match.group(1), encoding="utf-8")


def http_json(url: str, payload: dict | None = None, timeout: float = 30.0) -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"} if data is not None else {},
        method="POST" if data is not None else "GET",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def wait_for_health(base_url: str, proc: subprocess.Popen, timeout_s: float = 180.0) -> dict:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"Docs server exited prematurely with code {proc.returncode}")
        try:
            return http_json(f"{base_url}/health", timeout=2.0)
        except Exception:
            time.sleep(0.5)
    raise TimeoutError(f"Timed out waiting for {base_url}/health")


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate og Docs Phase 2 MLX embedder + reranker locally.")
    parser.add_argument("--embed-model", default=DEFAULT_EMBED_MODEL)
    parser.add_argument("--rerank-model", default=DEFAULT_RERANK_MODEL)
    parser.add_argument("--chunks", type=Path, default=None, help="Optional JSON list of {stable_id, title, text} chunks")
    parser.add_argument("--offline", action="store_true", help="Run uvx & HF Hub strictly offline")
    parser.add_argument("--top-n", type=int, default=30)
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    chunks = json.loads(args.chunks.read_text(encoding="utf-8")) if args.chunks else SAMPLE_CHUNKS
    port = free_loopback_port()
    base_url = f"http://127.0.0.1:{port}"

    with tempfile.TemporaryDirectory(prefix="og-docs-eval-") as tmp:
        script_path = Path(tmp) / "og_docs_server.py"
        extract_embedded_server(repo_root, script_path)

        cmd = ["uvx"]
        if args.offline:
            cmd.append("--offline")
        cmd += [
            "--with", "mlx",
            "--with", "tokenizers",
            "--with", "huggingface-hub",
            "--with", "numpy",
            "python3", str(script_path),
            "--host", "127.0.0.1",
            "--port", str(port),
            "--embed-model", args.embed_model,
            "--rerank-model", args.rerank_model,
        ]
        env = dict(os.environ)
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        if args.offline:
            env["UV_OFFLINE"] = "1"
            env["HF_HUB_OFFLINE"] = "1"

        t0 = time.perf_counter()
        proc = subprocess.Popen(cmd, env=env)
        try:
            health = wait_for_health(base_url, proc)
            startup_s = time.perf_counter() - t0
            print(f"Server ready in {startup_s:.2f}s: {health}")

            # Embed corpus in batches of 32
            t_emb = time.perf_counter()
            vecs: list[list[float]] = []
            texts = [c["text"] for c in chunks]
            for i in range(0, len(texts), 32):
                resp = http_json(
                    f"{base_url}/v1/embeddings",
                    {"model": args.embed_model, "input": texts[i:i + 32], "input_type": "passage"},
                    timeout=120.0,
                )
                items = sorted(resp["data"], key=lambda x: x["index"])
                vecs.extend(it["embedding"] for it in items)
            emb_s = time.perf_counter() - t_emb
            print(f"Embedded {len(chunks)} chunks in {emb_s:.2f}s ({len(chunks) / max(emb_s, 1e-6):.1f} chunks/s)\n")

            failures = 0
            for query, expected_symbols in GOLDEN_QUERIES:
                tq = time.perf_counter()
                q_resp = http_json(
                    f"{base_url}/v1/embeddings",
                    {"model": args.embed_model, "input": query, "input_type": "query"},
                )
                q_vec = q_resp["data"][0]["embedding"]
                sims = [sum(a * b for a, b in zip(v, q_vec)) for v in vecs]
                top_k = min(args.top_n, len(chunks))
                cand_idxs = sorted(range(len(chunks)), key=lambda i: -sims[i])[:top_k]
                cand_docs = [chunks[i]["text"] for i in cand_idxs]
                rr_resp = http_json(
                    f"{base_url}/v1/rerank",
                    {"model": args.rerank_model, "query": query, "documents": cand_docs, "top_n": min(5, len(cand_docs))},
                )
                dt_ms = (time.perf_counter() - tq) * 1000.0
                top3 = [
                    (chunks[cand_idxs[r["index"]]]["title"], r["relevance_score"])
                    for r in rr_resp["results"][:3]
                ]
                if expected_symbols:
                    ok = bool(top3) and any(sym in top3[0][0] for sym in expected_symbols)
                else:
                    ok = not top3 or top3[0][1] < 0.05
                status = "PASS" if ok else "FAIL"
                if not ok:
                    failures += 1
                print(f"[{status}] {query} ({dt_ms:.1f}ms) -> {[(t, round(s, 4)) for t, s in top3]}")

            return 1 if failures else 0
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    sys.exit(main())
