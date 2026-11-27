#!/usr/bin/env python3
"""
Reproducible local end-to-end evaluation script for og Docs Phase 3 (Issue #24, Y-12).

By default, extracts REAL Go stdlib chunks from `go env GOROOT` (or `--goroot`),
retrieves top-3 evidence chunks via SQLite FTS5, runs `uvx --from mlx-lm mlx_lm.server`
on `127.0.0.1:<free port>`, and verifies generated Go snippets locally via `go build`
(`GOPROXY=off`, `CGO_ENABLED=0`).

Usage:
    mise x go@1.23.6 -- python3 scripts/eval-docs-phase3.py --models mlx-community/Qwen2.5-Coder-3B-Instruct-4bit
    mise x go@1.23.6 -- python3 scripts/eval-docs-phase3.py --handwritten
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


SKIP_DIRS = {"internal", "vendor", "testdata", "cmd"}

STDLIB_PACKAGE_BY_IDENT = {
    "bufio": "bufio",
    "bytes": "bytes",
    "context": "context",
    "errors": "errors",
    "filepath": "path/filepath",
    "fmt": "fmt",
    "http": "net/http",
    "io": "io",
    "json": "encoding/json",
    "maps": "maps",
    "os": "os",
    "regexp": "regexp",
    "slices": "slices",
    "slog": "log/slog",
    "sort": "sort",
    "strconv": "strconv",
    "strings": "strings",
    "sync": "sync",
    "time": "time",
    "url": "net/url",
}

E2E_QUERIES = [
    {
        "name": "authorization_header_request",
        "query": "Authorization ヘッダをつけてリクエストを送りたい",
        "fts_terms": ["Authorization", "header", "http", "request"],
        "language": "Japanese",
        "expect_insufficient": False,
    },
    {
        "name": "read_file_line_by_line",
        "query": "ファイルを1行ずつ読みたい",
        "fts_terms": ["line", "lines", "file", "reading", "bufio"],
        "language": "Japanese",
        "expect_insufficient": False,
    },
    {
        "name": "json_indent_output",
        "query": "JSON を整形して出したい",
        "fts_terms": ["json", "indent", "format", "encoding"],
        "language": "Japanese",
        "expect_insufficient": False,
    },
    {
        "name": "context_timeout",
        "query": "処理にタイムアウトを付けたい",
        "fts_terms": ["timeout", "deadline", "context", "cancel"],
        "language": "Japanese",
        "expect_insufficient": False,
    },
    {
        "name": "unrelated_evidence_guard",
        "query": "量子テレポーテーション制御のAPIを使いたい",
        "fts_terms": ["Println", "fmt"],
        "language": "Japanese",
        "expect_insufficient": True,
    },
]

HANDWRITTEN_CASES = [
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


def detect_goroot(explicit: str | None) -> tuple[Path, str]:
    if explicit:
        p = Path(explicit)
    else:
        out = subprocess.check_output(["go", "env", "GOROOT"], text=True).strip()
        p = Path(out)
    ver_out = subprocess.check_output(["go", "version"], text=True).strip()
    m = re.search(r"go(\d+\.\d+)", ver_out)
    go_ver = m.group(1) if m else "1.23"
    return p, go_ver


def extract_goroot_chunks(goroot: Path) -> list[dict]:
    src = goroot / "src"
    chunks: list[dict] = []
    decl_re = re.compile(r"^(func|type)\s+(?:\([^)]+\)\s*)?([A-Z][A-Za-z0-9_]*)(.*)$")
    for root, dirs, files in os.walk(src):
        dirs[:] = [
            d for d in dirs
            if d not in SKIP_DIRS and not d.startswith("_") and not d.startswith(".")
        ]
        rel_pkg = os.path.relpath(root, src)
        if rel_pkg == ".":
            continue
        pkg = rel_pkg.replace(os.sep, "/")
        for fname in sorted(files):
            if not fname.endswith(".go") or fname.endswith("_test.go"):
                continue
            lines = (Path(root) / fname).read_text(encoding="utf-8", errors="ignore").splitlines()
            doc_buf: list[str] = []
            for line in lines:
                s = line.strip()
                if s.startswith("//"):
                    doc_buf.append(s[2:].strip())
                    continue
                m = decl_re.match(line)
                if m:
                    sym = m.group(2)
                    sig = line.rstrip("{").strip()
                    summary = " ".join(doc_buf[:3]).strip() or sig
                    doc_body = "\n".join(doc_buf).strip()
                    chunks.append({
                        "citation": f"Go Standard Library: {pkg}.{sym}",
                        "title": f"{pkg}.{sym}",
                        "package": pkg,
                        "symbol": sym,
                        "signature": sig,
                        "since": "",
                        "summary": summary[:400],
                        "doc": doc_body[:600],
                        "example": "",
                    })
                doc_buf = []
    return chunks


def build_fts_index(chunks: list[dict]) -> sqlite3.Connection:
    conn = sqlite3.connect(":memory:")
    conn.execute("CREATE VIRTUAL TABLE docs USING fts5(idx UNINDEXED, title, pkg, sym, summary)")
    conn.executemany(
        "INSERT INTO docs(idx, title, pkg, sym, summary) VALUES (?, ?, ?, ?, ?)",
        [(str(i), c["title"], c["package"], c["symbol"], c["summary"]) for i, c in enumerate(chunks)],
    )
    return conn


def search_fts(conn: sqlite3.Connection, chunks: list[dict], terms: list[str], limit: int = 3) -> list[dict]:
    match_expr = " OR ".join(f'"{t}"' for t in terms)
    rows = conn.execute(
        "SELECT idx, bm25(docs) AS rank FROM docs WHERE docs MATCH ? ORDER BY rank LIMIT ?",
        (match_expr, limit),
    ).fetchall()
    return [chunks[int(r[0])] for r in rows]


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
        "   <self-contained, compilable Go code (declare/initialize any needed variables such as req/url/f instead of referencing undefined context variables; include every used stdlib package if writing import)>\n"
        "   ```"
    )
    parts = [f"Query: {case['query']}", f"Target Go version: {target_ver}", "Evidence:"]
    for ev in case["evidence"]:
        block = (
            f"citation: {ev['citation']}\n"
            f"title: {ev['title']}\n"
            f"signature: {ev['signature']}\n"
            f"since: {ev['since']}\n"
            f"summary: {ev['summary']}"
        )
        if ev.get("example"):
            block += f"\nexample:\n{ev['example']}"
        if ev.get("doc"):
            block += f"\ndoc: {ev['doc'][:600]}"
        parts.append(block)
    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": "\n\n".join(parts)},
    ]


def parse_output(raw: str) -> dict | None:
    s = raw.strip()
    if "EXPLANATION:" in s or "INSUFFICIENT_EVIDENCE:" in s or "CITATIONS:" in s:
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
                    cites = [c.strip() for c in val.split("|") if c.strip()]
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
    if start != -1 and end != -1 and start < end:
        try:
            return json.loads(s[start : end + 1])
        except Exception:
            return None
    return None


def inject_imports_if_needed(extra_imports: list[str], source: str) -> str:
    unique = sorted(p for p in set(extra_imports) if not re.search(rf'(?m)^\s*(?:import\s+)?"{re.escape(p)}"\s*$', source))
    if not unique:
        return source
    added = "\n".join(f'\t"{p}"' for p in unique)
    m = re.search(r"(?m)^\s*import\s*\(", source)
    if m:
        return source[: m.end()] + "\n" + added + source[m.end() :]
    m = re.search(r'(?m)^\s*import\s+"([^"]+)"\s*$', source)
    if m:
        rep = f'import (\n\t"{m.group(1)}"\n{added}\n)'
        return source[: m.start()] + rep + source[m.end() :]
    m = re.search(r"(?m)^\s*package\s+\S+\s*$", source)
    if m:
        return source[: m.end()] + f"\n\nimport (\n{added}\n)" + source[m.end() :]
    return f"import (\n{added}\n)\n\n" + source


def wrap_go_snippet(snippet: str, extra_imports: list[str] | None = None) -> str:
    trimmed = snippet.strip()
    extras = extra_imports or []
    if re.match(r"(?m)^\s*package\s+", trimmed):
        return inject_imports_if_needed(extras, trimmed) + "\n"
    has_import = re.search(r'(?m)^\s*import(?:\s+"|\s*\()', trimmed) is not None
    if has_import:
        return f"package ogverify\n\n{inject_imports_if_needed(extras, trimmed)}\n"
    is_top_level = re.search(r"(?m)^\s*(?:func|type|import)\b", trimmed) is not None
    imports_block = ""
    if extras:
        lines = "\n".join(f'\t"{p}"' for p in sorted(set(extras)))
        imports_block = f"import (\n{lines}\n)\n\n"
    body = trimmed if is_top_level else f"func _ogVerify() {{\n{trimmed}\n}}"
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
        env.update({"GOPROXY": "off", "GOSUMDB": "off", "GOWORK": "off", "GOTOOLCHAIN": "local", "CGO_ENABLED": "0"})
        proc = subprocess.run([go_exe, "build", "-mod=readonly", "./..."], cwd=tmp, env=env, capture_output=True, text=True, timeout=20)
        if proc.returncode != 0:
            missing = []
            for line in proc.stderr.splitlines():
                if "undefined: " in line:
                    ident = line.split("undefined: ", 1)[1].strip().split()[0].rstrip(".")
                    pkg = STDLIB_PACKAGE_BY_IDENT.get(ident)
                    if pkg and pkg not in missing:
                        missing.append(pkg)
            if missing:
                Path(tmp, "main.go").write_text(wrap_go_snippet(snippet, missing), encoding="utf-8")
                proc = subprocess.run([go_exe, "build", "-mod=readonly", "./..."], cwd=tmp, env=env, capture_output=True, text=True, timeout=20)
        if proc.returncode == 0:
            return "verified", "ok"
        first_lines = " | ".join(l.strip() for l in proc.stderr.splitlines() if l.strip() and not l.startswith("#"))[:160]
        return "failed", first_lines
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def evaluate_model(model_id: str, uvx_path: str, cases: list[dict]) -> dict:
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
        for case in cases:
            if not case["evidence"]:
                # Phase 2 retrieval returned Not Found -> Phase 3 synthesis skipped (honest Not Found)
                results.append({
                    "name": case["name"],
                    "status": "pass_not_found_guard" if case["expect_insufficient"] else "fail_no_evidence",
                    "retrieved": 0,
                })
                continue
            req_body = json.dumps({
                "model": model_id,
                "messages": build_messages(case),
                "temperature": 0.1,
                "max_tokens": 1024,
                "stream": False,
            }).encode("utf-8")
            req = urllib.request.Request(
                f"http://127.0.0.1:{port}/v1/chat/completions",
                data=req_body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            q0 = time.time()
            with urllib.request.urlopen(req, timeout=60.0) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            latency_ms = round((time.time() - q0) * 1000, 1)
            content = payload["choices"][0]["message"]["content"]
            parsed = parse_output(content)
            if not parsed:
                results.append({"name": case["name"], "status": "parse_failed", "latency_ms": latency_ms, "raw": content[:200]})
                continue
            insuff = bool(parsed.get("insufficient_evidence", False))
            if case["expect_insufficient"]:
                results.append({"name": case["name"], "status": "pass" if insuff else "fail_fabricated", "latency_ms": latency_ms})
            else:
                cites = parsed.get("citations") or []
                valid_exact = {ev["citation"].lower() for ev in case["evidence"]} | {ev["title"].lower() for ev in case["evidence"]}
                grounded = any(c.strip().strip("`\"'").lower() in valid_exact for c in cites)
                snippet = parsed.get("snippet") or ""
                verif_status, verif_msg = verify_go_snippet(snippet, case["target_go"]) if snippet else ("no_snippet", "")
                passed = (not insuff) and grounded and verif_status == "verified"
                results.append({
                    "name": case["name"],
                    "status": "pass" if passed else f"fail({verif_status},grounded={grounded})",
                    "latency_ms": latency_ms,
                    "retrieved": len(case["evidence"]),
                    "citations": cites,
                    "verify": verif_status,
                    "verify_msg": verif_msg,
                })
        return {"model": model_id, "startup_s": startup_s, "cases": results}
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--goroot", default=None)
    parser.add_argument("--handwritten", action="store_true")
    parser.add_argument(
        "--models",
        nargs="+",
        default=["mlx-community/Qwen2.5-Coder-3B-Instruct-4bit"],
    )
    args = parser.parse_args()
    uvx_path = shutil.which("uvx") or os.path.expanduser("~/.local/bin/uvx")
    if not os.path.exists(uvx_path):
        print("uvx not found", file=sys.stderr)
        return 1

    if args.handwritten:
        cases = HANDWRITTEN_CASES
        corpus_desc = "handwritten-3"
    else:
        goroot, go_ver = detect_goroot(args.goroot)
        chunks = extract_goroot_chunks(goroot)
        conn = build_fts_index(chunks)
        corpus_desc = f"real-GOROOT({go_ver}, {len(chunks)} chunks)"
        cases = []
        for q in E2E_QUERIES:
            ev = search_fts(conn, chunks, q["fts_terms"], limit=3)
            cases.append({
                "name": q["name"],
                "query": q["query"],
                "language": q["language"],
                "target_go": go_ver,
                "expect_insufficient": q["expect_insufficient"],
                "evidence": ev,
            })

    summary = {"corpus": corpus_desc, "results": [evaluate_model(m, uvx_path, cases) for m in args.models]}
    print("\n=== SUMMARY ===")
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
