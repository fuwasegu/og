#!/usr/bin/env python3
"""
Reproducible local evaluation script for og Docs Phase 3 (Issue #24).

Launches `uvx --from mlx-lm mlx_lm.server` on 127.0.0.1:<free port>, sends the
exact structured-output prompt used by `LoopbackChatAnswerGenerator`, and
verifies generated Go snippets locally via `go build` (`GOPROXY=off`).

Usage:
    python3 scripts/eval-docs-phase3.py --models mlx-community/Qwen2.5-Coder-1.5B-4bit mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit mlx-community/Qwen2.5-Coder-3B-Instruct-4bit
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


GOLDEN_CASES = [
    {
        "name": "authorization_header_request",
        "query": "Authorization ヘッダをつけてリクエストを送りたい",
        "language": "Japanese",
        "target_go": "1.23",
        "expect_insufficient": False,
        "evidence": [
            {
                "citation": "Go Standard Library: net/http.NewRequest",
                "title": "net/http.NewRequest",
                "signature": "func NewRequest(method, url string, body io.Reader) (*Request, error)",
                "since": "1.0",
                "summary": "NewRequest returns a new Request given a method, URL, and optional body.",
                "example": 'req, err := http.NewRequest(http.MethodGet, "https://example.com", nil)',
            },
            {
                "citation": "Go Standard Library: net/http.Header.Set",
                "title": "net/http.Header.Set",
                "signature": "func (h Header) Set(key, value string)",
                "since": "1.0",
                "summary": "Set sets the header entries associated with key to the single element value.",
                "example": 'req.Header.Set("Authorization", "Bearer token")',
            },
            {
                "citation": "Go Standard Library: net/http.Client.Do",
                "title": "net/http.Client.Do",
                "signature": "func (c *Client) Do(req *Request) (*Response, error)",
                "since": "1.0",
                "summary": "Do sends an HTTP request and returns an HTTP response.",
                "example": "resp, err := http.DefaultClient.Do(req)",
            },
        ],
    },
    {
        "name": "read_file_line_by_line",
        "query": "ファイルを1行ずつ読みたい",
        "language": "Japanese",
        "target_go": "1.23",
        "expect_insufficient": False,
        "evidence": [
            {
                "citation": "Go Standard Library: bufio.Scanner",
                "title": "bufio.Scanner",
                "signature": "type Scanner struct",
                "since": "1.1",
                "summary": "Scanner provides a convenient interface for reading data such as a file of newline-delimited lines of text.",
                "example": 'f, err := os.Open("file.txt")\nif err != nil { return err }\ndefer f.Close()\nsc := bufio.NewScanner(f)\nfor sc.Scan() {\n\tfmt.Println(sc.Text())\n}\nreturn sc.Err()',
            },
        ],
    },
    {
        "name": "insufficient_evidence_guard",
        "query": "量子テレポーテーション制御のAPIを使いたい",
        "language": "Japanese",
        "target_go": "1.23",
        "expect_insufficient": True,
        "evidence": [
            {
                "citation": "Go Standard Library: fmt.Println",
                "title": "fmt.Println",
                "signature": "func Println(a ...any) (n int, err error)",
                "since": "1.0",
                "summary": "Println formats using the default formats for its operands and writes to standard output.",
                "example": 'fmt.Println("hello")',
            },
        ],
    },
]

STDLIB_IMPORTS = {
    "bufio.": "bufio",
    "bytes.": "bytes",
    "context.": "context",
    "errors.": "errors",
    "filepath.": "path/filepath",
    "fmt.": "fmt",
    "http.": "net/http",
    "io.": "io",
    "json.": "encoding/json",
    "os.": "os",
    "regexp.": "regexp",
    "slices.": "slices",
    "sort.": "sort",
    "strconv.": "strconv",
    "strings.": "strings",
    "sync.": "sync",
    "time.": "time",
}


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def wait_health(port: int, timeout_s: float = 300.0) -> bool:
    deadline = time.time() + timeout_s
    url = f"http://127.0.0.1:{port}/v1/models"
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2.0) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


def build_messages(case: dict) -> list[dict[str, str]]:
    target_ver = case["target_go"]
    lang_hint = case["language"]
    system_prompt = (
        f"You are an offline Go documentation assistant for Go {target_ver}.\n"
        "Rules:\n"
        "1. Answer ONLY using the provided Evidence. Never invent Go symbols or packages.\n"
        "2. If no Evidence entry can answer the query, write `CITATIONS: none` and `SNIPPET: none`.\n"
        "3. Reply using these exact headers:\n"
        "   CITATIONS: <copy exact citation strings from Evidence, separated by |>\n"
        "   REQUIRES_NEWER_GO: none\n"
        "   EXPLANATION:\n"
        f"   <1-2 concise sentences in {lang_hint}>\n"
        "   SNIPPET:\n"
        "   ```go\n"
        "   <concise compilable Go code; if writing import, include every used stdlib package>\n"
        "   ```"
    )
    parts = [f"Query: {case['query']}", f"Target Go version: {target_ver}", "Evidence:"]
    for ev in case["evidence"]:
        block = (
            f"citation: {ev['citation']}\n"
            f"title: {ev['title']}\n"
            f"signature: {ev['signature']}\n"
            f"since: {ev['since']}\n"
            f"summary: {ev['summary']}\n"
            f"example:\n{ev['example']}"
        )
        parts.append(block)
    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": "\n\n".join(parts)},
    ]


def parse_json_output(raw: str) -> dict | None:
    s = raw.strip()
    if "EXPLANATION:" in s or "INSUFFICIENT_EVIDENCE:" in s:
        insuff = False
        cites: list[str] = []
        expl_lines: list[str] = []
        snip_lines: list[str] = []
        sec = None
        in_fence = False
        for line in s.splitlines():
            t = line.strip()
            if t.startswith("INSUFFICIENT_EVIDENCE:"):
                insuff = t.split(":", 1)[1].strip().lower() in ("true", "yes")
                sec = None
            elif t.startswith("REQUIRES_NEWER_GO:"):
                sec = None
            elif t.startswith("CITATIONS:"):
                val = t.split(":", 1)[1]
                if val.strip().lower() in ("none", "null"):
                    insuff = True
                    cites = []
                else:
                    sep = "|" if "|" in val else ","
                    cites = [c.strip() for c in val.split(sep) if c.strip()]
                sec = None
            elif t.startswith("EXPLANATION:"):
                rest = t.split(":", 1)[1].strip()
                if rest:
                    expl_lines.append(rest)
                sec = "expl"
            elif t.startswith("SNIPPET:"):
                sec = "snip"
            elif sec == "expl" and t:
                expl_lines.append(line)
            elif sec == "snip":
                if t.startswith("```"):
                    in_fence = not in_fence
                    continue
                if in_fence or t or snip_lines:
                    snip_lines.append(line)
        expl = "\n".join(expl_lines).strip()
        snip = "\n".join(snip_lines).strip()
        if insuff:
            return {"insufficient_evidence": True, "explanation": expl, "citations": [], "snippet": None}
        if expl:
            return {"insufficient_evidence": False, "explanation": expl, "citations": cites, "snippet": snip or None}
    start = s.find("{")
    end = s.rfind("}")
    if start == -1 or end == -1 or start >= end:
        return None
    try:
        return json.loads(s[start : end + 1])
    except Exception:
        return None


def wrap_go_snippet(snippet: str) -> str:
    trimmed = snippet.strip()
    if trimmed.startswith("package "):
        return trimmed + "\n"
    needs_func = not (
        trimmed.startswith("func ")
        or trimmed.startswith("type ")
        or trimmed.startswith("import ")
    )
    imports_block = ""
    if "import " not in trimmed and "import(" not in trimmed:
        inferred = sorted(pkg for prefix, pkg in STDLIB_IMPORTS.items() if prefix in trimmed)
        if inferred:
            lines = "\n".join(f'\t"{p}"' for p in inferred)
            imports_block = f"import (\n{lines}\n)\n\n"
    body = f"func _ogVerify() {{\n{trimmed}\n}}" if needs_func else trimmed
    return f"package ogverify\n\n{imports_block}{body}\n"


def verify_go_snippet(snippet: str, go_ver: str) -> tuple[str, str]:
    go_exe = shutil.which("go")
    if not go_exe:
        return "unverified", "go toolchain not found"
    tmp = tempfile.mkdtemp(prefix="og-eval-p3-")
    try:
        Path(tmp, "go.mod").write_text(f"module ogverify\n\ngo {go_ver}\n", encoding="utf-8")
        Path(tmp, "main.go").write_text(wrap_go_snippet(snippet), encoding="utf-8")
        env = dict(os.environ)
        env.update({"GOPROXY": "off", "GOSUMDB": "off", "GOWORK": "off", "GOTOOLCHAIN": "local"})
        proc = subprocess.run(
            [go_exe, "build", "-mod=readonly", "./..."],
            cwd=tmp,
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        if proc.returncode == 0:
            return "verified", "ok"
        first_lines = " | ".join(
            l.strip() for l in proc.stderr.splitlines() if l.strip() and not l.startswith("#")
        )[:160]
        return "failed", first_lines
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def evaluate_model(model_id: str, uvx_path: str) -> dict:
    port = free_port()
    cmd = [uvx_path, "--from", "mlx-lm", "mlx_lm.server", "--model", model_id, "--host", "127.0.0.1", "--port", str(port)]
    env = dict(os.environ)
    env["HF_HUB_DISABLE_TELEMETRY"] = "1"
    print(f"\n=== Evaluating {model_id} on 127.0.0.1:{port} ===", flush=True)
    t0 = time.time()
    proc = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    results = []
    try:
        if not wait_health(port, timeout_s=300.0):
            return {"model": model_id, "error": "health check timed out", "cases": []}
        startup_s = round(time.time() - t0, 2)
        print(f"Ready in {startup_s}s", flush=True)
        for case in GOLDEN_CASES:
            req_body = json.dumps(
                {
                    "model": model_id,
                    "messages": build_messages(case),
                    "temperature": 0.1,
                    "max_tokens": 1024,
                    "stream": False,
                }
            ).encode("utf-8")
            req = urllib.request.Request(
                f"http://127.0.0.1:{port}/v1/chat/completions",
                data=req_body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            q0 = time.time()
            try:
                with urllib.request.urlopen(req, timeout=60.0) as resp:
                    payload = json.loads(resp.read().decode("utf-8"))
                latency_ms = round((time.time() - q0) * 1000, 1)
                content = payload["choices"][0]["message"]["content"]
                parsed = parse_json_output(content)
                if not parsed:
                    results.append({"name": case["name"], "status": "invalid_json", "latency_ms": latency_ms, "raw": content[:200]})
                    continue
                insuff = bool(parsed.get("insufficient_evidence", False))
                if case["expect_insufficient"]:
                    passed = insuff
                    results.append({"name": case["name"], "status": "pass" if passed else "fail_fabricated", "latency_ms": latency_ms, "insufficient": insuff})
                else:
                    cites = parsed.get("citations") or []
                    valid_cites = {ev["citation"] for ev in case["evidence"]}
                    grounded = any(any(vc in c or c in vc for vc in valid_cites) for c in cites)
                    snippet = parsed.get("snippet") or ""
                    verif_status, verif_msg = verify_go_snippet(snippet, case["target_go"]) if snippet else ("no_snippet", "")
                    passed = (not insuff) and grounded and verif_status == "verified"
                    results.append({
                        "name": case["name"],
                        "status": "pass" if passed else f"fail({verif_status},grounded={grounded},insuff={insuff})",
                        "latency_ms": latency_ms,
                        "citations": cites,
                        "verify": verif_status,
                        "verify_msg": verif_msg,
                    })
            except urllib.error.HTTPError as e:
                err_body = e.read().decode("utf-8", errors="replace")[:200]
                results.append({"name": case["name"], "status": f"http_{e.code}", "error": err_body})
            except Exception as e:
                results.append({"name": case["name"], "status": "error", "error": str(e)})
        return {"model": model_id, "startup_s": startup_s, "cases": results}
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--models",
        nargs="+",
        default=[
            "mlx-community/Qwen2.5-Coder-1.5B-4bit",
            "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit",
        ],
    )
    args = parser.parse_args()
    uvx_path = shutil.which("uvx") or os.path.expanduser("~/.local/bin/uvx")
    if not os.path.exists(uvx_path):
        print("uvx not found", file=sys.stderr)
        return 1
    summary = [evaluate_model(m, uvx_path) for m in args.models]
    print("\n=== SUMMARY ===")
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
