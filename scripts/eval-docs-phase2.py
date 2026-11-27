#!/usr/bin/env python3
"""
Reproducible local evaluation script for og Docs Phase 2 (Issue #21, V-7).

Extracts the embedded `og_docs_server.py` directly from
`Sources/OgCore/Docs/DocsModelServerCommand.swift`, launches it on
`127.0.0.1:<free port>` via `uvx` (Apple Silicon MLX), and evaluates golden
queries against a REAL Go standard library corpus by default:

Corpus resolution order (real GOROOT by default; never falls back silently to
a handwritten sample):
  1. `--pack-db <path/to/index.sqlite>`  — reads real chunks directly from an installed og pack DB
  2. `--chunks <path/to/chunks.json>`    — reads JSON exported by `DocsPackManager.exportChunksJSON` / `DebugDriver docsexport`
  3. `--goroot <path>` or `go env GOROOT` (DEFAULT) — extracts real Go stdlib chunks from `<GOROOT>/src`
  4. `--sample` (explicit opt-in only)   — tiny 8-chunk smoke sample when no Go toolchain is present

Usage:
    python3 scripts/eval-docs-phase2.py                     # real GOROOT/src via `go env GOROOT`
    python3 scripts/eval-docs-phase2.py --offline           # zero network (requires cached uv/HF models)
    python3 scripts/eval-docs-phase2.py --pack-db ~/Library/Application\\ Support/og/docs-packs/packs/go1.23/index.sqlite --offline
    python3 scripts/eval-docs-phase2.py --chunks /path/to/exported-chunks.json --offline
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path


DEFAULT_EMBED_MODEL = "mlx-community/bge-m3-mlx-8bit"
DEFAULT_RERANK_MODEL = "caslca/bge-reranker-v2-m3-mlx-8bit"

SKIP_DIRS = {"internal", "vendor", "testdata", "cmd"}

SAMPLE_CHUNKS = [
    {
        "stable_id": "stdlib:encoding/json:Unmarshal",
        "title": "encoding/json.Unmarshal",
        "content_hash": "sample-json-unmarshal",
        "text": "encoding/json.Unmarshal\nUnmarshal parses the JSON-encoded data and stores the result in the value pointed to by v.\nfunc Unmarshal(data []byte, v any) error",
        "rerank_text": "encoding/json.Unmarshal\nUnmarshal parses the JSON-encoded data and stores the result in the value pointed to by v.\nfunc Unmarshal(data []byte, v any) error",
    },
    {
        "stable_id": "stdlib:encoding/json:Decoder",
        "title": "encoding/json.Decoder",
        "content_hash": "sample-json-decoder",
        "text": "encoding/json.Decoder\nA Decoder reads and decodes JSON values from an input stream.\ntype Decoder struct",
        "rerank_text": "encoding/json.Decoder\nA Decoder reads and decodes JSON values from an input stream.\ntype Decoder struct",
    },
    {
        "stable_id": "stdlib:encoding/json:Encoder",
        "title": "encoding/json.Encoder",
        "content_hash": "sample-json-encoder",
        "text": "encoding/json.Encoder\nAn Encoder writes JSON values to an output stream. Call SetIndent to indent output.\ntype Encoder struct",
        "rerank_text": "encoding/json.Encoder\nAn Encoder writes JSON values to an output stream. Call SetIndent to indent output.\ntype Encoder struct",
    },
    {
        "stable_id": "stdlib:encoding/json:MarshalIndent",
        "title": "encoding/json.MarshalIndent",
        "content_hash": "sample-json-marshalindent",
        "text": "encoding/json.MarshalIndent\nMarshalIndent is like Marshal but applies Indent to format the output.\nfunc MarshalIndent(v any, prefix, indent string) ([]byte, error)",
        "rerank_text": "encoding/json.MarshalIndent\nMarshalIndent is like Marshal but applies Indent to format the output.\nfunc MarshalIndent(v any, prefix, indent string) ([]byte, error)",
    },
    {
        "stable_id": "stdlib:bufio:Scanner",
        "title": "bufio.Scanner",
        "content_hash": "sample-bufio-scanner",
        "text": "bufio.Scanner\nScanner provides a convenient interface for reading data such as a file of newline-delimited lines of text.\ntype Scanner struct",
        "rerank_text": "bufio.Scanner\nScanner provides a convenient interface for reading data such as a file of newline-delimited lines of text.\ntype Scanner struct",
    },
    {
        "stable_id": "stdlib:context:WithTimeout",
        "title": "context.WithTimeout",
        "content_hash": "sample-context-withtimeout",
        "text": "context.WithTimeout\nWithTimeout returns WithDeadline(parent, time.Now().Add(timeout)).\nfunc WithTimeout(parent Context, timeout time.Duration) (Context, CancelFunc)",
        "rerank_text": "context.WithTimeout\nWithTimeout returns WithDeadline(parent, time.Now().Add(timeout)).\nfunc WithTimeout(parent Context, timeout time.Duration) (Context, CancelFunc)",
    },
    {
        "stable_id": "stdlib:regexp:Compile",
        "title": "regexp.Compile",
        "content_hash": "sample-regexp-compile",
        "text": "regexp.Compile\nCompile parses a regular expression and returns, if successful, a Regexp object that can be used to match against text.\nfunc Compile(expr string) (*Regexp, error)",
        "rerank_text": "regexp.Compile\nCompile parses a regular expression and returns, if successful, a Regexp object that can be used to match against text.\nfunc Compile(expr string) (*Regexp, error)",
    },
    {
        "stable_id": "stdlib:slices:Compact",
        "title": "slices.Compact",
        "content_hash": "sample-slices-compact",
        "text": "slices.Compact\nCompact replaces consecutive runs of equal elements with a single copy.\nfunc Compact[S ~[]E, E comparable](s S) S",
        "rerank_text": "slices.Compact\nCompact replaces consecutive runs of equal elements with a single copy.\nfunc Compact[S ~[]E, E comparable](s S) S",
    },
]

# Golden queries: (query, expected_substrings_in_top_k, top_k_check)
# Empty expected list indicates a negative (non-existent feature) query expected to be rejected by threshold (< 0.05).
GOLDEN_QUERIES = [
    ("json のデコード", ["encoding/json.Unmarshal", "encoding/json.Decoder"], 1),
    ("ファイルを1行ずつ読みたい", ["bufio.Scanner"], 1),
    ("JSON を整形して出したい", ["encoding/json.MarshalIndent", "encoding/json.Encoder", "encoding/json.Indent"], 3),
    ("処理にタイムアウトを付けたい", ["context.WithTimeout"], 1),
    ("標準ライブラリに正規表現ある？", ["regexp"], 1),
    ("重複を取り除きたい", ["slices.Compact"], 3),
    ("スライスをソートしたい", ["slices.Sort", "sort.Slice", "sort.Sort"], 3),
    ("文字列を連結したい", ["strings.Builder", "strings.Join"], 3),
    ("goroutine の完了待ち", ["sync.WaitGroup"], 1),
    ("ディレクトリを再帰的に一覧したい", ["path/filepath.WalkDir", "path/filepath.Walk"], 3),
    ("標準ライブラリに量子テレポーテーション制御ある？", [], 1),
    ("標準ライブラリにブロックチェーンのスマートコントラクトある？", [], 1),
]

# Issue #25 diagnostic query: checks whether GOROOT official Example*() functions cover HTTP Authorization headers.
AUTHORIZATION_DIAGNOSTIC_QUERY = "Authorization ヘッダをつけてリクエストを送りたい"
AUTH_HEADER_RE = re.compile(
    r"Authorization|Bearer|SetBasicAuth|BasicAuth|Header\.Set|Header\.Add|http\.Header|Header\s*\{",
    re.IGNORECASE,
)

# Issue #26 (E-1) positive surfacing queries: verify golang/website narrative content actually surfaces in top-k.
WEBSITE_POSITIVE_QUERIES = [
    ("defer cleanup LIFO", ["Effective Go", "A Tour of Go", "Defer"], 3),
    ("Why is there no type inheritance", ["Frequently Asked Questions"], 3),
    ("canceling database operations timeout", ["Cancel Operations"], 3),
    ("goroutine leak profile", ["Goroutine Leak"], 3),
]


def parse_bundled_concept_rules(repo_root: Path) -> list[tuple[list[str], list[str], list[str]]]:
    """Reads `BundledGoCorpus.defaultConceptRules` directly from Swift source (no duplicated rules)."""
    swift_path = repo_root / "Sources/OgCore/Docs/BundledGoCorpus.swift"
    if not swift_path.exists():
        return []
    src = swift_path.read_text(encoding="utf-8")
    rules = []
    for line in src.splitlines():
        if "DocsConceptRule(" not in line:
            continue
        tm = re.search(r"triggers:\s*\[([^\]]*)\]", line)
        em = re.search(r"expansions:\s*\[([^\]]*)\]", line)
        xm = re.search(r"excludeIfPresent:\s*\[([^\]]*)\]", line)
        if not tm or not em:
            continue
        triggers = re.findall(r'"([^"]+)"', tm.group(1))
        expansions = re.findall(r'"([^"]+)"', em.group(1))
        excludes = re.findall(r'"([^"]+)"', xm.group(1)) if xm else []
        rules.append((triggers, excludes, expansions))
    return rules


def build_fts_index(chunks: list[dict]) -> sqlite3.Connection:
    conn = sqlite3.connect(":memory:")
    conn.execute(
        "CREATE VIRTUAL TABLE chunks_fts USING fts5(idx UNINDEXED, title, package_name, symbol, text, tokenize='unicode61')"
    )
    rows = []
    for i, c in enumerate(chunks):
        title = c["title"]
        if title.startswith("package "):
            pkg, sym = title[len("package "):], ""
        elif "." in title:
            pkg, sym = title.split(".", 1)
        else:
            pkg, sym = "", title
        rows.append((i, title, pkg, sym, c["text"]))
    conn.executemany(
        "INSERT INTO chunks_fts (idx, title, package_name, symbol, text) VALUES (?, ?, ?, ?, ?)",
        rows,
    )
    return conn


def query_search_terms(query: str, concept_rules: list[tuple[list[str], list[str], list[str]]]) -> list[str]:
    lower = query.lower()
    terms: list[str] = []
    for tok in re.findall(r"[A-Za-z][A-Za-z0-9_./]*", query):
        if len(tok) >= 2 and tok not in terms:
            terms.append(tok)
    for triggers, excludes, expansions in concept_rules:
        if any(ex.lower() in lower for ex in excludes):
            continue
        if any(tr.lower() in lower for tr in triggers):
            for exp in expansions:
                if exp not in terms:
                    terms.append(exp)
    return terms


def fts_search_indices(conn: sqlite3.Connection, terms: list[str], limit: int = 20) -> list[int]:
    if not terms:
        return []
    safe_terms = []
    for t in terms:
        cleaned = re.sub(r'[^A-Za-z0-9_]', ' ', t).strip()
        for part in cleaned.split():
            if len(part) >= 2 and part not in safe_terms:
                safe_terms.append(part)
    if not safe_terms:
        return []
    fts_expr = " OR ".join(f'"{t}"' for t in safe_terms[:12])
    try:
        rows = conn.execute(
            "SELECT idx FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts, 8.0, 6.0, 10.0, 1.0) LIMIT ?",
            (fts_expr, limit),
        ).fetchall()
        return [int(r[0]) for r in rows]
    except sqlite3.Error:
        return []


def package_matches(title: str, lower_terms: set[str]) -> bool:
    """Mirrors `ResearchService.swift:702` package-level intent bonus (+4.0)."""
    if title.startswith("package "):
        pkg = title[len("package "):].lower()
    elif "." in title:
        pkg = title.split(".", 1)[0].lower()
    else:
        return False
    short_pkg = pkg.split("/")[-1]
    return pkg in lower_terms or short_pkg in lower_terms


def lexical_match_strength(title: str, lower_terms: set[str]) -> int:
    """Mirrors `ResearchService.lexicalMatchStrength` (2 = exact symbol, 1 = package/method-prefix, 0 = none)."""
    if not lower_terms:
        return 0
    if title.startswith("package "):
        pkg = title[len("package "):].lower()
        short_pkg = pkg.split("/")[-1]
        return 1 if (pkg in lower_terms or short_pkg in lower_terms) else 0
    if "." in title:
        pkg, sym = title.split(".", 1)
    else:
        pkg, sym = "", title
    pkg_l = pkg.lower()
    short_pkg = pkg_l.split("/")[-1]
    sym_l = sym.lower()
    if sym_l in lower_terms:
        return 2
    if any(sym_l.startswith(t + ".") or pkg_l == t or short_pkg == t for t in lower_terms):
        return 1
    return 0


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


def detect_goroot() -> Path | None:
    if os.environ.get("GOROOT"):
        p = Path(os.environ["GOROOT"])
        if (p / "src").is_dir():
            return p
    try:
        out = subprocess.check_output(["go", "env", "GOROOT"], text=True, stderr=subprocess.DEVNULL).strip()
        if out and (Path(out) / "src").is_dir():
            return Path(out)
    except Exception:
        pass
    return None


def _is_exported(name: str) -> bool:
    return bool(name) and name[0].isupper()


def _clean_doc_lines(lines: list[str]) -> str:
    cleaned = []
    for ln in lines:
        s = ln.strip()
        if s.startswith("//"):
            s = s[2:]
            if s.startswith(" "):
                s = s[1:]
        cleaned.append(s)
    return "\n".join(cleaned).strip()


def extract_real_goroot_chunks(goroot: Path, include_examples: bool = True) -> list[dict]:
    """Extracts exported GoDoc chunks (and optionally official Example*() chunks) from real `<GOROOT>/src`."""
    src_root = goroot / "src"
    if not src_root.is_dir():
        raise FileNotFoundError(f"GOROOT src directory not found: {src_root}")

    func_re = re.compile(r"^func\s+([A-Z][A-Za-z0-9_]*)\s*(?:\[[^\n]*\])?\s*\(")
    method_re = re.compile(r"^func\s+\(\s*(?:[A-Za-z0-9_]+\s+)?\*?([A-Z][A-Za-z0-9_]*)(?:\[[^\n]*\])?\s*\)\s+([A-Z][A-Za-z0-9_]*)\s*\(")
    type_re = re.compile(r"^type\s+([A-Z][A-Za-z0-9_]*)\b")
    var_const_re = re.compile(r"^(?:var|const)\s+([A-Z][A-Za-z0-9_]*)\b")
    pkg_re = re.compile(r"^package\s+([A-Za-z0-9_]+)\b")

    chunks: list[dict] = []
    seen_ids: set[str] = set()

    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames[:] = sorted(
            d for d in dirnames
            if d not in SKIP_DIRS and not d.startswith(".") and not d.startswith("_")
        )
        rel = Path(dirpath).relative_to(src_root)
        if str(rel) == ".":
            continue
        import_path = rel.as_posix()
        if any(part in SKIP_DIRS or part.startswith("_") or part.startswith(".") for part in rel.parts):
            continue

        go_files = sorted(
            f for f in filenames
            if f.endswith(".go") and not f.endswith("_test.go") and not f.startswith("_")
        )
        test_files = sorted(
            f for f in filenames
            if f.endswith("_test.go") and not f.startswith("_")
        )
        if not go_files and not test_files:
            continue

        for fname in go_files:
            fpath = Path(dirpath) / fname
            try:
                raw = fpath.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            lines = raw.splitlines()
            comment_buf: list[str] = []
            for line in lines:
                stripped = line.strip()
                if stripped.startswith("//"):
                    if stripped.startswith("//go:") or stripped.startswith("// +build"):
                        continue
                    comment_buf.append(stripped)
                    continue
                if stripped == "":
                    comment_buf = []
                    continue

                doc = _clean_doc_lines(comment_buf)
                comment_buf = []

                pm = pkg_re.match(line)
                if pm:
                    if doc and f"stdlib:{import_path}:" not in seen_ids:
                        sid = f"stdlib:{import_path}:"
                        seen_ids.add(sid)
                        summary = doc.split("\n\n")[0].replace("\n", " ")[:240]
                        text = f"package {import_path}\n{summary}\n{doc[:800]}"
                        chunks.append({
                            "stable_id": sid,
                            "title": f"package {import_path}",
                            "content_hash": hashlib.sha256(text.encode("utf-8")).hexdigest()[:24],
                            "text": text,
                            "rerank_text": text[:900],
                        })
                    continue

                sym = None
                sig = line.rstrip("{").strip()
                mm = method_re.match(line)
                if mm:
                    sym = f"{mm.group(1)}.{mm.group(2)}"
                else:
                    fm = func_re.match(line)
                    if fm:
                        sym = fm.group(1)
                    else:
                        tm = type_re.match(line)
                        if tm:
                            sym = tm.group(1)
                        else:
                            vm = var_const_re.match(line)
                            if vm:
                                sym = vm.group(1)

                if sym and _is_exported(sym.split(".")[0]):
                    sid = f"stdlib:{import_path}:{sym}"
                    if sid in seen_ids:
                        continue
                    seen_ids.add(sid)
                    summary = (doc.split("\n\n")[0].replace("\n", " ") if doc else sig)[:240]
                    title = f"{import_path}.{sym}"
                    body = doc[:800] if doc else sig
                    text = f"{title}\n{summary}\n{sig}\n{body}"
                    chunks.append({
                        "stable_id": sid,
                        "title": title,
                        "content_hash": hashlib.sha256(text.encode("utf-8")).hexdigest()[:24],
                        "text": text,
                        "rerank_text": text[:900],
                    })

        # Also extract official Example*() functions from *_test.go (Issue #25).
        ex_re = re.compile(r"^func\s+(Example(?:_[A-Za-z0-9_]+|[A-Z][A-Za-z0-9_]*)?)\(\)\s*\{")
        for fname in (test_files if include_examples else []):
            fpath = Path(dirpath) / fname
            try:
                raw = fpath.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            lines = raw.splitlines()
            comment_buf = []
            idx = 0
            while idx < len(lines):
                line = lines[idx]
                stripped = line.strip()
                if stripped.startswith("//"):
                    if stripped.startswith("//go:") or stripped.startswith("// +build"):
                        idx += 1
                        continue
                    comment_buf.append(stripped)
                    idx += 1
                    continue
                if stripped == "":
                    comment_buf = []
                    idx += 1
                    continue
                em = ex_re.match(line)
                if em:
                    ex_name = em.group(1)
                    doc = _clean_doc_lines(comment_buf)
                    comment_buf = []
                    body_lines = []
                    idx += 1
                    while idx < len(lines) and not lines[idx].startswith("}"):
                        body_lines.append(lines[idx])
                        idx += 1
                    code = "\n".join(body_lines).strip()
                    if code:
                        rest = ex_name[len("Example"):]
                        if not rest or rest.startswith("_"):
                            target_sym = ""
                            suffix = rest.lstrip("_") or None
                        else:
                            parts = rest.split("_")
                            if len(parts) >= 2 and parts[1] and parts[1][0].isupper():
                                target_sym = f"{parts[0]}.{parts[1]}"
                                suffix = "_".join(parts[2:]) or None
                            else:
                                target_sym = parts[0]
                                suffix = "_".join(parts[1:]) or None
                        target_disp = f"{import_path}.{target_sym}" if target_sym else import_path
                        title = f"Example: {target_disp} ({suffix})" if suffix else f"Example: {target_disp}"
                        sid = f"stdlib::{import_path}::{import_path}::{target_sym}::example::{import_path}.{ex_name}"
                        if sid not in seen_ids:
                            seen_ids.add(sid)
                            summary = (doc.split("\n\n")[0].replace("\n", " ") if doc else f"Official Go example for {target_disp}.")[:240]
                            text = f"{title}\nfunc {ex_name}()\n{summary}\n{code[:800]}"
                            full_text = f"{title}\nfunc {ex_name}()\n{doc}\n{code}"
                            chunks.append({
                                "stable_id": sid,
                                "title": title,
                                "content_hash": hashlib.sha256(text.encode("utf-8")).hexdigest()[:24],
                                "text": text,
                                "full_text": full_text,
                                "rerank_text": text[:900],
                            })
                    idx += 1
                    continue
                comment_buf = []
                idx += 1

    return chunks


def extract_website_chunks(website_root: Path) -> list[dict]:
    """Extracts curated golang/website chunks (Effective Go, Tour, FAQ, Guides, technical Blog) for eval regression checks (Issue #26)."""
    content_root = website_root / "_content" if (website_root / "_content").is_dir() else website_root
    chunks: list[dict] = []
    seen_ids: set[str] = set()

    def add_chunk(doc_id: str, heading: str, title: str, body: str, url: str) -> None:
        body = body.strip()
        if not body:
            return
        sid = f"guide::{doc_id}::::{heading}::section::#{re.sub(r'[^A-Za-z0-9]+', '_', heading).strip('_') or 'section'}"
        if sid in seen_ids:
            return
        seen_ids.add(sid)
        summary = re.sub(r"\s+", " ", body)[:240]
        text = f"{title}\n{summary}\n{body[:800]}"
        chunks.append({
            "stable_id": sid,
            "title": title,
            "content_hash": hashlib.sha256(text.encode("utf-8")).hexdigest()[:24],
            "text": text,
            "full_text": f"{title}\n{url}\n{body}",
            "rerank_text": text[:900],
            "source_url": url,
        })

    # 1. Effective Go HTML
    eff = content_root / "doc/effective_go.html"
    if eff.is_file():
        raw = eff.read_text(encoding="utf-8", errors="ignore")
        parts = re.split(r'(<h[23][^>]*>.*?</h[23]>)', raw, flags=re.IGNORECASE | re.DOTALL)
        for i in range(1, len(parts) - 1, 2):
            m = re.match(r'<h[23](?:\s+[^>]*?id="([^"]+)")?[^>]*>(.*?)</h[23]>', parts[i], flags=re.IGNORECASE | re.DOTALL)
            if not m:
                continue
            anchor = m.group(1) or "section"
            heading = re.sub(r"<[^>]+>", "", m.group(2)).strip()
            body = re.sub(r"<[^>]+>", " ", parts[i + 1])
            body = re.sub(r"\s+", " ", body).strip()
            add_chunk("website/doc/effective_go", heading, f"Effective Go: {heading}", body, f"https://go.dev/doc/effective_go#{anchor}")

    # 2. Tour of Go .article
    tour_dir = content_root / "tour"
    for chap in ("welcome", "basics", "flowcontrol", "moretypes", "methods", "generics", "concurrency"):
        art = tour_dir / f"{chap}.article"
        if not art.is_file():
            continue
        lines = art.read_text(encoding="utf-8", errors="ignore").splitlines()
        chap_title = lines[0].strip() if lines else chap
        slide_idx = 0
        cur_heading = None
        cur_lines: list[str] = []
        for ln in lines[1:]:
            if ln.startswith("* "):
                if cur_heading:
                    slide_idx += 1
                    add_chunk(f"website/tour/{chap}", cur_heading, f"A Tour of Go: {chap_title} — {cur_heading}", "\n".join(cur_lines), f"https://go.dev/tour/{chap}/{slide_idx}")
                cur_heading = ln[2:].strip()
                cur_lines = []
            elif cur_heading is not None:
                if ln.startswith(".play ") or ln.startswith(".code "):
                    rel = ln.split()[1]
                    go_f = tour_dir / rel
                    if go_f.is_file():
                        cur_lines.append(go_f.read_text(encoding="utf-8", errors="ignore")[:800])
                elif not ln.startswith("."):
                    cur_lines.append(ln)
        if cur_heading:
            slide_idx += 1
            add_chunk(f"website/tour/{chap}", cur_heading, f"A Tour of Go: {chap_title} — {cur_heading}", "\n".join(cur_lines), f"https://go.dev/tour/{chap}/{slide_idx}")

    # 3. Markdown docs (FAQ, guides, technical blog)
    excluded_blog_prefixes = ("survey", "gophercon", "gopherchina", "gothamgo", "gouk", "contributor", "oscon", "io20", "gophergala", "brand", "go-brand", "store", "turkey-doodle")
    md_targets: list[tuple[Path, str, str]] = []
    if (content_root / "doc/faq.md").is_file():
        md_targets.append((content_root / "doc/faq.md", "website/doc/faq", "https://go.dev/doc/faq"))
    for sub in ("doc/tutorial", "doc/database", "doc/modules", "wiki"):
        d = content_root / sub
        if d.is_dir():
            for f in sorted(d.glob("*.md")):
                if f.name != "index.md":
                    md_targets.append((f, f"website/{sub}/{f.stem}", f"https://go.dev/{sub}/{f.stem}"))
    blog_dir = content_root / "blog"
    if blog_dir.is_dir():
        for f in sorted(blog_dir.glob("*.md")):
            slug = f.stem.lower()
            if re.match(r"^go1(\.\d+)", slug) or slug.endswith("years") or any(slug.startswith(p) for p in excluded_blog_prefixes):
                continue
            md_targets.append((f, f"website/blog/{f.stem}", f"https://go.dev/blog/{f.stem}"))

    for md_path, doc_id, base_url in md_targets:
        raw = md_path.read_text(encoding="utf-8", errors="ignore")
        title = md_path.stem.replace("-", " ").title()
        if raw.startswith("---\n"):
            end = raw.find("\n---", 4)
            if end != -1:
                fm = raw[4:end]
                tm = re.search(r'^title:\s*["\']?(.+?)["\']?\s*$', fm, re.MULTILINE)
                if tm:
                    title = tm.group(1).strip()
                raw = raw[end + 4:]
        cur_heading = title
        cur_lines = []
        in_fence = False
        for ln in raw.splitlines():
            st = ln.strip()
            if st.startswith("```"):
                in_fence = not in_fence
                cur_lines.append(ln)
                continue
            if not in_fence and re.match(r"^#{2,4}\s+", st):
                add_chunk(doc_id, cur_heading, f"{title}: {cur_heading}" if cur_heading != title else title, "\n".join(cur_lines), base_url)
                cur_heading = re.sub(r"\s*\{#[^}]+\}\s*$", "", re.sub(r"^#{2,4}\s+", "", st)).strip()
                cur_lines = []
            else:
                cur_lines.append(ln)
        add_chunk(doc_id, cur_heading, f"{title}: {cur_heading}" if cur_heading != title else title, "\n".join(cur_lines), base_url)

    return chunks


def load_chunks_from_pack_db(db_path: Path) -> list[dict]:
    """Reads chunks directly from an installed og `index.sqlite` pack."""
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        rows = conn.execute(
            "SELECT stable_id, title, summary, signature, body, content_hash FROM chunks ORDER BY stable_id"
        ).fetchall()
    finally:
        conn.close()
    out = []
    for sid, title, summary, sig, body, chash in rows:
        parts = [p for p in (title, summary, sig or "", (body or "")[:800]) if p]
        text = "\n".join(parts)
        out.append({
            "stable_id": sid,
            "title": title,
            "content_hash": chash or hashlib.sha256(text.encode("utf-8")).hexdigest()[:24],
            "text": text,
            "rerank_text": text[:900],
        })
    return out


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


def l2_norm(v: list[float]) -> float:
    return math.sqrt(math.fsum(x * x for x in v))


def cosine_sim(a: list[float], a_norm: float, b: list[float], b_norm: float) -> float:
    if a_norm <= 0.0 or b_norm <= 0.0:
        return 0.0
    return math.fsum(x * y for x, y in zip(a, b)) / (a_norm * b_norm)


def open_vec_cache(cache_path: Path | None) -> sqlite3.Connection | None:
    if cache_path is None:
        return None
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(cache_path))
    conn.execute(
        "CREATE TABLE IF NOT EXISTS eval_vecs (model TEXT NOT NULL, content_hash TEXT NOT NULL, vec BLOB NOT NULL, PRIMARY KEY (model, content_hash))"
    )
    conn.commit()
    return conn


def pack_f32(vec: list[float]) -> bytes:
    return struct.pack(f"<{len(vec)}f", *vec)


def unpack_f32(blob: bytes) -> list[float]:
    n = len(blob) // 4
    return list(struct.unpack(f"<{n}f", blob))


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate og Docs Phase 2 MLX embedder + reranker locally.")
    parser.add_argument("--embed-model", default=DEFAULT_EMBED_MODEL)
    parser.add_argument("--rerank-model", default=DEFAULT_RERANK_MODEL)
    parser.add_argument("--pack-db", type=Path, default=None, help="Path to an installed og pack index.sqlite")
    parser.add_argument("--chunks", type=Path, default=None, help="Path to JSON exported by DocsPackManager.exportChunksJSON / docsexport")
    parser.add_argument("--goroot", type=Path, default=None, help="Path to local GOROOT (defaults to `go env GOROOT`)")
    parser.add_argument("--website", type=Path, default=None, help="Path to local golang/website checkout (appends curated website snapshot chunks)")
    parser.add_argument("--sample", action="store_true", help="Explicitly use tiny 8-chunk smoke sample instead of real GOROOT")
    parser.add_argument("--offline", action="store_true", help="Run uvx & HF Hub strictly offline")
    parser.add_argument("--semantic-only", action="store_true", help="Disable Stage 1 FTS5 union (ablation mode)")
    parser.add_argument("--fts-only", action="store_true", help="Evaluate FTS5 stage only without launching MLX server (for fast Before/After regression checks)")
    parser.add_argument("--no-examples", action="store_true", help="Exclude official Example*() chunks (reproduces pre-Issue-#25 baseline)")
    parser.add_argument("--top-n", type=int, default=30)
    parser.add_argument("--cache-file", type=Path, default=Path(tempfile.gettempdir()) / "og-eval-docs-phase2-cache.sqlite")
    parser.add_argument("--no-cache", action="store_true", help="Disable local embedding vector cache")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent

    if args.pack_db is not None:
        corpus_desc = f"og pack DB ({args.pack_db})"
        chunks = load_chunks_from_pack_db(args.pack_db)
    elif args.chunks is not None:
        corpus_desc = f"exported JSON ({args.chunks})"
        raw_chunks = json.loads(args.chunks.read_text(encoding="utf-8"))
        chunks = []
        for c in raw_chunks:
            text = c.get("text") or c.get("embedding_text") or ""
            chunks.append({
                "stable_id": c["stable_id"],
                "title": c["title"],
                "content_hash": c.get("content_hash") or hashlib.sha256(text.encode("utf-8")).hexdigest()[:24],
                "text": text,
                "rerank_text": c.get("rerank_text") or text[:900],
            })
    elif args.sample:
        corpus_desc = "explicit --sample (8 chunks)"
        chunks = SAMPLE_CHUNKS
    else:
        goroot = args.goroot or detect_goroot()
        if goroot is None:
            print("ERROR: Could not detect GOROOT (`go env GOROOT`). Pass --goroot, --pack-db, --chunks, or --sample.", file=sys.stderr)
            return 2
        corpus_desc = f"real GOROOT/src ({goroot})"
        t_ext = time.perf_counter()
        chunks = extract_real_goroot_chunks(goroot, include_examples=not args.no_examples)
        ex_cnt = sum(1 for c in chunks if "::example::" in c["stable_id"])
        print(f"Extracted {len(chunks)} real GoDoc chunks (doc={len(chunks) - ex_cnt}, example={ex_cnt}) from {goroot}/src in {time.perf_counter() - t_ext:.2f}s")

    if args.no_examples:
        chunks = [c for c in chunks if "::example::" not in c["stable_id"]]

    if args.website is not None:
        t_web = time.perf_counter()
        web_chunks = extract_website_chunks(args.website)
        print(f"Extracted {len(web_chunks)} golang/website snapshot chunks from {args.website} in {time.perf_counter() - t_web:.2f}s")
        chunks.extend(web_chunks)
        corpus_desc += f" + golang/website ({len(web_chunks)} chunks)"

    if not chunks:
        print("ERROR: Corpus has 0 chunks.", file=sys.stderr)
        return 2

    ex_total = sum(1 for c in chunks if "::example::" in c["stable_id"])
    net_http_ex = [c for c in chunks if "::example::" in c["stable_id"] and ("::net/http::" in c["stable_id"] or "::net/http/" in c["stable_id"])]
    auth_ex_hits = [
        c["title"]
        for c in chunks
        if "::example::" in c["stable_id"] and AUTH_HEADER_RE.search(c.get("full_text") or c["text"])
    ]
    print(f"Corpus summary: total={len(chunks)} (doc={len(chunks) - ex_total}, example={ex_total}, net/http* examples={len(net_http_ex)}, auth/header example matches={auth_ex_hits})")

    if args.fts_only:
        concept_rules = parse_bundled_concept_rules(repo_root)
        fts_conn = build_fts_index(chunks)
        print(f"Corpus: {corpus_desc} ({len(chunks)} chunks)")
        print("Pipeline: fts-only (Stage 1 FTS5 baseline — MLX embedder/reranker disabled)\n")
        failures = 0
        for query, expected_symbols, check_top_k in GOLDEN_QUERIES:
            tq = time.perf_counter()
            terms = query_search_terms(query, concept_rules)
            fts_idxs = fts_search_indices(fts_conn, terms, limit=10)
            dt_ms = (time.perf_counter() - tq) * 1000.0
            top3 = [chunks[i]["title"] for i in fts_idxs[:3]]
            if expected_symbols:
                checked = top3[:check_top_k]
                ok = bool(checked) and any(any(exp in title for exp in expected_symbols) for title in checked)
            else:
                ok = len(top3) == 0
            status = "PASS" if ok else "FAIL"
            if not ok:
                failures += 1
            print(f"[{status}] {query} ({dt_ms:.1f}ms) -> {top3 if top3 else ['Not Found (0 cards)']}")
        # Diagnostic query: Authorization header request
        auth_terms = query_search_terms(AUTHORIZATION_DIAGNOSTIC_QUERY, concept_rules)
        auth_idxs = fts_search_indices(fts_conn, auth_terms, limit=10)
        auth_top3 = [chunks[i]["title"] for i in auth_idxs[:3]]
        print(f"[DIAG] {AUTHORIZATION_DIAGNOSTIC_QUERY} -> {auth_top3 if auth_top3 else ['Not Found (0 cards)']}")

        # Issue #26 (E-1): Positive surfacing check when --website is supplied
        web_failures = 0
        if args.website is not None:
            print("\nWebsite positive surfacing checks (Issue #26 E-1):")
            for wq, w_expected, w_k in WEBSITE_POSITIVE_QUERIES:
                wt = query_search_terms(wq, concept_rules)
                w_idxs = fts_search_indices(fts_conn, wt, limit=10)
                w_top = [chunks[i]["title"] for i in w_idxs[:3]]
                w_ok = bool(w_top[:w_k]) and any(any(exp.lower() in title.lower() for exp in w_expected) for title in w_top[:w_k])
                if not w_ok:
                    web_failures += 1
                print(f"[{'PASS' if w_ok else 'FAIL'}] {wq} -> {w_top if w_top else ['Not Found (0 cards)']}")
            print(f"Website positive summary: {len(WEBSITE_POSITIVE_QUERIES) - web_failures}/{len(WEBSITE_POSITIVE_QUERIES)} PASS")

        fts_conn.close()
        total = len(GOLDEN_QUERIES)
        print(f"\nSummary (FTS-only): {total - failures}/{total} PASS")
        return 1 if (failures or web_failures) else 0

    port = free_loopback_port()
    base_url = f"http://127.0.0.1:{port}"

    cache_conn = None if args.no_cache else open_vec_cache(args.cache_file)

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
            print(f"Corpus: {corpus_desc} ({len(chunks)} chunks)")
            print(f"Server ready in {startup_s:.2f}s: {health}")

            # Load cached vectors and embed missing chunks in batches of 32
            cached_map: dict[str, list[float]] = {}
            if cache_conn is not None:
                rows = cache_conn.execute(
                    "SELECT content_hash, vec FROM eval_vecs WHERE model = ?",
                    (args.embed_model,),
                ).fetchall()
                for chash, blob in rows:
                    cached_map[chash] = unpack_f32(blob)

            vecs: list[list[float] | None] = [None] * len(chunks)
            missing_indices: list[int] = []
            reused = 0
            for idx, c in enumerate(chunks):
                hit = cached_map.get(c["content_hash"])
                if hit is not None:
                    vecs[idx] = hit
                    reused += 1
                else:
                    missing_indices.append(idx)

            t_emb = time.perf_counter()
            if missing_indices:
                for start in range(0, len(missing_indices), 32):
                    batch_idxs = missing_indices[start:start + 32]
                    batch_texts = [chunks[i]["text"] for i in batch_idxs]
                    resp = http_json(
                        f"{base_url}/v1/embeddings",
                        {"model": args.embed_model, "input": batch_texts, "input_type": "passage"},
                        timeout=120.0,
                    )
                    items = sorted(resp["data"], key=lambda x: x["index"])
                    to_insert = []
                    for idx, item in zip(batch_idxs, items):
                        v = item["embedding"]
                        norm = l2_norm(v)
                        if not (0.98 <= norm <= 1.02):
                            raise AssertionError(f"Expected unit-normalized embedding from server, got L2 norm={norm:.4f}")
                        vecs[idx] = v
                        if cache_conn is not None:
                            to_insert.append((args.embed_model, chunks[idx]["content_hash"], pack_f32(v)))
                    if cache_conn is not None and to_insert:
                        cache_conn.executemany(
                            "INSERT OR REPLACE INTO eval_vecs (model, content_hash, vec) VALUES (?, ?, ?)",
                            to_insert,
                        )
                        cache_conn.commit()
                    done = min(start + 32, len(missing_indices))
                    if done % 640 == 0 or done == len(missing_indices):
                        elapsed = time.perf_counter() - t_emb
                        print(f"  embedded {done}/{len(missing_indices)} new chunks ({done / max(elapsed, 1e-6):.1f} chunks/s)", flush=True)
            emb_s = time.perf_counter() - t_emb
            computed = len(missing_indices)
            print(f"Vectors ready: {len(chunks)} total (computed={computed} in {emb_s:.2f}s, reused={reused})\n")

            final_vecs = [v for v in vecs if v is not None]
            norms = [l2_norm(v) for v in final_vecs]
            concept_rules = [] if args.semantic_only else parse_bundled_concept_rules(repo_root)
            fts_conn = None if args.semantic_only else build_fts_index(chunks)
            mode_label = "semantic-only + rerank (ablation)" if args.semantic_only else "hybrid (FTS5 + semantic union top-30) + rerank"
            print(f"Pipeline: {mode_label}\n")

            failures = 0
            for query, expected_symbols, check_top_k in GOLDEN_QUERIES:
                tq = time.perf_counter()
                terms = query_search_terms(query, concept_rules)
                lower_terms = {t.lower() for t in terms if len(t) >= 2}
                fts_idxs = fts_search_indices(fts_conn, terms, limit=20) if fts_conn is not None else []
                fts_rank_map = {idx: rank for rank, idx in enumerate(fts_idxs)}

                q_resp = http_json(
                    f"{base_url}/v1/embeddings",
                    {"model": args.embed_model, "input": query, "input_type": "query"},
                )
                q_vec = q_resp["data"][0]["embedding"]
                q_norm = l2_norm(q_vec)
                if not (0.98 <= q_norm <= 1.02):
                    raise AssertionError(f"Expected unit-normalized query embedding, got L2 norm={q_norm:.4f}")
                sims = [cosine_sim(v, n, q_vec, q_norm) for v, n in zip(final_vecs, norms)]
                top_k = min(args.top_n, len(chunks))
                sem_idxs = sorted(range(len(chunks)), key=lambda i: -sims[i])[:top_k]

                # Balanced Stage 1 union pool mirroring ResearchService.swift Step 5 (up to top_k/2 FTS + Semantic -> top_k)
                pool: list[int] = []
                seen: set[int] = set()
                for idx in fts_idxs[: top_k // 2]:
                    if idx not in seen and len(pool) < top_k:
                        seen.add(idx)
                        pool.append(idx)
                for idx in sem_idxs:
                    if idx not in seen and len(pool) < top_k:
                        seen.add(idx)
                        pool.append(idx)

                cand_docs = [chunks[i]["rerank_text"] for i in pool]
                rr_resp = http_json(
                    f"{base_url}/v1/rerank",
                    {"model": args.rerank_model, "query": query, "documents": cand_docs, "top_n": len(cand_docs)},
                )
                dt_ms = (time.perf_counter() - tq) * 1000.0
                rr_map = {r["index"]: float(r["relevance_score"]) for r in rr_resp["results"]}

                # Mirror ResearchService.swift Step 5 fusion & anti-hallucination thresholds
                is_existence = "ある？" in query or "ある?" in query
                sem_threshold = 0.05 if is_existence else 0.015
                scored = []
                for pos, cidx in enumerate(pool):
                    rr = rr_map.get(pos, 0.0)
                    title = chunks[cidx]["title"]
                    is_fts = cidx in fts_rank_map
                    lex_strength = lexical_match_strength(title, lower_terms) if is_fts else 0
                    if not is_fts and rr < sem_threshold:
                        continue
                    if is_fts and lex_strength == 0 and rr < 0.015:
                        continue
                    if args.semantic_only:
                        final_score = rr * 100.0
                    else:
                        fts_bonus = (8.0 / (fts_rank_map[cidx] + 1)) if is_fts else 0.0
                        if lex_strength >= 2:
                            lex_bonus = 50.0 + fts_bonus
                        elif lex_strength == 1:
                            lex_bonus = 38.0 + fts_bonus
                        elif is_fts:
                            lex_bonus = fts_bonus
                        else:
                            lex_bonus = 0.0
                        pkg_bonus = 4.0 if (is_fts and package_matches(title, lower_terms)) else 0.0
                        final_score = rr * 100.0 + lex_bonus + pkg_bonus
                    scored.append((final_score, rr, title))

                scored.sort(key=lambda x: (-x[0], x[2]))
                top3 = [(title, rr) for _, rr, title in scored[:3]]
                if expected_symbols:
                    checked = top3[:check_top_k]
                    ok = bool(checked) and any(
                        any(exp in title for exp in expected_symbols)
                        for title, _ in checked
                    )
                else:
                    ok = len(top3) == 0
                status = "PASS" if ok else "FAIL"
                if not ok:
                    failures += 1
                if top3:
                    rendered = [(t, round(s, 4)) for t, s in top3]
                else:
                    rendered = ["Not Found (0 cards)"]
                print(f"[{status}] {query} ({dt_ms:.1f}ms) -> {rendered}")

            if fts_conn is not None:
                fts_conn.close()
            total = len(GOLDEN_QUERIES)
            print(f"\nSummary: {total - failures}/{total} PASS")
            return 1 if failures else 0
        finally:
            if cache_conn is not None:
                cache_conn.close()
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    sys.exit(main())
