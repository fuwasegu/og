import Foundation

/// Inference backend for the og-owned Docs research server (Issue #21, Q-2, D-9).
public enum DocsInferenceBackend: String, Sendable, CaseIterable, Codable {
    case mlx
    case custom

    public var title: String {
        switch self {
        case .mlx: return "MLX (Unified Embedder + Reranker via uvx)"
        case .custom: return "Custom command"
        }
    }
}

/// Selectable multilingual embedding model preset for Go Docs semantic search (Issue #21, D-10).
public struct DocsEmbedModelPreset: Sendable, Hashable {
    public var id: String
    public var version: String
    public var title: String
    public var license: String
    public var pooling: String
    public var queryPrefix: String
    public var documentPrefix: String

    public init(
        id: String,
        version: String,
        title: String,
        license: String,
        pooling: String,
        queryPrefix: String = "",
        documentPrefix: String = ""
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.license = license
        self.pooling = pooling
        self.queryPrefix = queryPrefix
        self.documentPrefix = documentPrefix
    }

    public var descriptor: EmbeddingModelDescriptor {
        EmbeddingModelDescriptor(id: id, version: version)
    }

    /// Benchmarked presets on real GOROOT (11,421 chunks, Issue #21).
    public static let all: [DocsEmbedModelPreset] = [
        DocsEmbedModelPreset(
            id: "mlx-community/bge-m3-mlx-8bit",
            version: "mlx-8bit-v1",
            title: "BGE-M3 8-bit MLX (Recommended — MIT, ~576 MB)",
            license: "MIT",
            pooling: "cls"
        ),
        DocsEmbedModelPreset(
            id: "intfloat/multilingual-e5-small",
            version: "e5-small-fp16-v1",
            title: "Multilingual E5 Small (Lightweight — MIT, ~449 MB)",
            license: "MIT",
            pooling: "mean",
            queryPrefix: "query: ",
            documentPrefix: "passage: "
        )
    ]

    public static let `default` = all[0]

    public static func matching(id: String) -> DocsEmbedModelPreset? {
        all.first { $0.id == id }
    }
}

/// Selectable multilingual cross-encoder reranker preset (Issue #21, D-10).
public struct DocsRerankModelPreset: Sendable, Hashable {
    public var id: String
    public var title: String
    public var license: String

    public init(id: String, title: String, license: String) {
        self.id = id
        self.title = title
        self.license = license
    }

    /// Benchmarked presets (Issue #21). Jina Reranker v2 is excluded due to CC-BY-NC-4.0 license.
    public static let all: [DocsRerankModelPreset] = [
        DocsRerankModelPreset(
            id: "caslca/bge-reranker-v2-m3-mlx-8bit",
            title: "BGE-Reranker-v2-M3 8-bit MLX (Recommended — Apache-2.0, ~577 MB)",
            license: "Apache-2.0"
        )
    ]

    public static let `default` = all[0]

    public static func matching(id: String) -> DocsRerankModelPreset? {
        all.first { $0.id == id }
    }
}

/// Persisted configuration for the og-owned Docs inference server (D-9, D-10, Q-2).
public struct DocsServerConfig: Sendable, Hashable, Codable {
    public var backend: DocsInferenceBackend
    public var embedModel: String
    public var embedModelVersion: String
    public var rerankEnabled: Bool
    public var rerankModel: String
    /// Custom command for `.custom`; `{port}` is replaced with the chosen loopback port.
    public var customCommand: String

    public init(
        backend: DocsInferenceBackend = .mlx,
        embedModel: String = DocsEmbedModelPreset.default.id,
        embedModelVersion: String = DocsEmbedModelPreset.default.version,
        rerankEnabled: Bool = true,
        rerankModel: String = DocsRerankModelPreset.default.id,
        customCommand: String = ""
    ) {
        self.backend = backend
        self.embedModel = embedModel
        self.embedModelVersion = embedModelVersion
        self.rerankEnabled = rerankEnabled
        self.rerankModel = rerankModel
        self.customCommand = customCommand
    }

    /// Descriptor used to tag vectors in `SharedVectorStore` and pack manifests (FR-27, FR-30).
    public var embeddingDescriptor: EmbeddingModelDescriptor {
        let trimmedID = embedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preset = DocsEmbedModelPreset.matching(id: trimmedID) {
            return preset.descriptor
        }
        let ver = embedModelVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return EmbeddingModelDescriptor(id: trimmedID, version: ver.isEmpty ? "custom-v1" : ver)
    }

    public var healthPath: String { "/health" }

    /// Stable key identifying the exact model/backend configuration for offline-cached launch reuse (W-8).
    public var cacheKey: String {
        let rr = rerankEnabled ? rerankModel.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return "\(backend.rawValue)|\(embedModel.trimmingCharacters(in: .whitespacesAndNewlines))|\(rerankEnabled)|\(rr)"
    }
}

/// Sliding-window crash restart and backoff policy for the Docs inference server
/// (`spec/req/docs_server.fsl`, `spec/design/docs_server.fsl`, V-5).
public struct DocsServerRestartPolicy: Sendable, Equatable {
    public let maxFailures: Int
    public let windowSeconds: TimeInterval
    public let baseBackoffSeconds: TimeInterval
    public private(set) var failureTimestamps: [Date] = []

    public init(
        maxFailures: Int = 3,
        windowSeconds: TimeInterval = 120,
        baseBackoffSeconds: TimeInterval = 1.0
    ) {
        self.maxFailures = max(1, maxFailures)
        self.windowSeconds = max(1, windowSeconds)
        self.baseBackoffSeconds = max(0, baseBackoffSeconds)
    }

    /// Removes failures older than the sliding crash window.
    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        failureTimestamps.removeAll { $0 < cutoff }
    }

    /// Records a failure (startup exit, health timeout, or Ready crash) at `now`.
    /// Returns whether another restart is allowed, the backoff delay in seconds, and the windowed count.
    public mutating func recordFailure(at now: Date) -> (shouldRetry: Bool, delaySeconds: TimeInterval, failureCount: Int) {
        prune(now: now)
        failureTimestamps.append(now)
        let count = failureTimestamps.count
        guard count < maxFailures else {
            return (false, 0, count)
        }
        let exponent = max(0, count - 1)
        let delay = min(8.0, baseBackoffSeconds * pow(2.0, Double(exponent)))
        return (true, delay, count)
    }

    public mutating func reset() {
        failureTimestamps.removeAll()
    }
}

/// Builds launch commands and manages the embedded MLX server script for the Docs inference server
/// (D-9, DES-6 in `spec/design/research.fsl`).
public enum DocsModelServerCommand {
    public static var defaultServerScriptURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("og/docs-server", isDirectory: true)
            .appendingPathComponent("og_docs_server.py")
    }

    /// Writes the embedded MLX unified inference server script to disk if missing or outdated.
    @discardableResult
    public static func ensureServerScript(at url: URL = defaultServerScriptURL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let desired = Data(embeddedMLXServerScript.utf8)
        if let existing = try? Data(contentsOf: url), existing == desired {
            return url
        }
        try desired.write(to: url, options: .atomic)
        return url
    }

    /// Builds argv for the Docs inference server bound strictly to `127.0.0.1:<port>` (D-9, DES-1, DES-6, W-8).
    /// When `offline` is true, passes `--offline` to `uvx` so cached packages and models start with zero network access.
    public static func argv(
        for config: DocsServerConfig,
        port: Int,
        offline: Bool = false,
        scriptURL: URL? = nil,
        locator: ToolLocator = .shared
    ) throws -> [String] {
        switch config.backend {
        case .mlx:
            guard let uvx = locator.find("uvx") else {
                throw ModelServerCommandError.missingTool("uvx")
            }
            let script = try ensureServerScript(at: scriptURL ?? defaultServerScriptURL)
            let embedID = config.embedModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !embedID.isEmpty else {
                throw ModelServerCommandError.emptyCustomCommand
            }
            let preset = DocsEmbedModelPreset.matching(id: embedID)
            var cmd = [uvx]
            if offline {
                cmd.append("--offline")
            }
            cmd += [
                "--with", "mlx",
                "--with", "tokenizers",
                "--with", "huggingface-hub",
                "--with", "numpy",
                "python3", script.path,
                "--host", "127.0.0.1",
                "--port", String(port),
                "--embed-model", embedID,
                "--embed-pooling", preset?.pooling ?? (embedID.lowercased().contains("e5") ? "mean" : "cls")
            ]
            if let qPrefix = preset?.queryPrefix, !qPrefix.isEmpty {
                cmd += ["--query-prefix", qPrefix]
            }
            if let dPrefix = preset?.documentPrefix, !dPrefix.isEmpty {
                cmd += ["--doc-prefix", dPrefix]
            }
            let rerankID = config.rerankModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if config.rerankEnabled, !rerankID.isEmpty {
                cmd += ["--rerank-model", rerankID]
            }
            return cmd

        case .custom:
            let raw = config.customCommand.replacingOccurrences(of: "{port}", with: String(port))
            let parts = ModelServerCommand.shellSplit(raw)
            guard let first = parts.first else {
                throw ModelServerCommandError.emptyCustomCommand
            }
            if first.hasPrefix("/") { return parts }
            guard let exe = locator.find(first) else {
                throw ModelServerCommandError.missingTool(first)
            }
            return [exe] + parts.dropFirst()
        }
    }

    /// Unified local-only Apple Silicon MLX HTTP server for XLM-RoBERTa embeddings & cross-encoder reranking.
    ///
    /// Endpoints (loopback `127.0.0.1` only):
    /// - `GET  /health`        -> `{"status":"ok","embed_model":...,"rerank_model":...,"rerank_ready":bool,"dim":int}`
    /// - `POST /v1/embeddings` -> OpenAI-compatible embeddings (single string or string array)
    /// - `POST /v1/rerank`     -> `{"results":[{"index":i,"relevance_score":p}, ...]}`
    ///
    /// Offline-first: attempts `local_files_only=True` before touching the network so cached models
    /// start offline in ~3s with zero outbound traffic.
    public static let embeddedMLXServerScript: String = #"""
#!/usr/bin/env python3
"""
og Docs local MLX inference server (loopback only, D-9 / DOC-6 / DOC-10).
Serves XLM-RoBERTa embeddings (/v1/embeddings) and cross-encoder reranking (/v1/rerank).
"""

import argparse
import json
import os
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import mlx.core as mx
import mlx.nn as nn
import numpy as np
from huggingface_hub import hf_hub_download
from tokenizers import Tokenizer


os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"


def download_offline_first(repo_id: str, filename: str) -> str:
    """Prefer local HF cache so offline startup works without any network calls."""
    if os.path.isdir(repo_id):
        local = os.path.join(repo_id, filename)
        if os.path.exists(local):
            return local
    try:
        return hf_hub_download(repo_id, filename, local_files_only=True)
    except Exception:
        print(f"Downloading {repo_id}/{filename}...", flush=True)
        return hf_hub_download(repo_id, filename)


class Embeddings(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.word_embeddings = nn.Embedding(c["vocab_size"], c["hidden_size"])
        self.position_embeddings = nn.Embedding(c["max_position_embeddings"], c["hidden_size"])
        self.token_type_embeddings = nn.Embedding(c.get("type_vocab_size", 1), c["hidden_size"])
        self.LayerNorm = nn.LayerNorm(c["hidden_size"], eps=c.get("layer_norm_eps", 1e-5))
        self.pad_id = c.get("pad_token_id", 1)

    def __call__(self, input_ids, attention_mask):
        pos_ids = (mx.cumsum(attention_mask, axis=1) * attention_mask + self.pad_id).astype(mx.int32)
        tt_ids = mx.zeros_like(input_ids)
        x = self.word_embeddings(input_ids) + self.position_embeddings(pos_ids) + self.token_type_embeddings(tt_ids)
        return self.LayerNorm(x)


class SelfAttention(nn.Module):
    def __init__(self, c):
        super().__init__()
        h = c["hidden_size"]
        self.num_heads = c["num_attention_heads"]
        self.head_dim = h // self.num_heads
        self.scale = self.head_dim ** -0.5
        self.query = nn.Linear(h, h)
        self.key = nn.Linear(h, h)
        self.value = nn.Linear(h, h)

    def __call__(self, x, mask_bias):
        B, L, D = x.shape
        q = self.query(x).reshape(B, L, self.num_heads, self.head_dim).transpose(0, 2, 1, 3)
        k = self.key(x).reshape(B, L, self.num_heads, self.head_dim).transpose(0, 2, 1, 3)
        v = self.value(x).reshape(B, L, self.num_heads, self.head_dim).transpose(0, 2, 1, 3)
        out = mx.fast.scaled_dot_product_attention(q, k, v, scale=self.scale, mask=mask_bias)
        return out.transpose(0, 2, 1, 3).reshape(B, L, D)


class AttentionOutput(nn.Module):
    def __init__(self, c):
        super().__init__()
        h = c["hidden_size"]
        self.dense = nn.Linear(h, h)
        self.LayerNorm = nn.LayerNorm(h, eps=c.get("layer_norm_eps", 1e-5))

    def __call__(self, hidden, residual):
        return self.LayerNorm(self.dense(hidden) + residual)


class Attention(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.self = SelfAttention(c)
        self.output = AttentionOutput(c)

    def __call__(self, x, mask_bias):
        return self.output(self.self(x, mask_bias), x)


class Intermediate(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.dense = nn.Linear(c["hidden_size"], c["intermediate_size"])

    def __call__(self, x):
        return nn.gelu(self.dense(x))


class LayerOutput(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.dense = nn.Linear(c["intermediate_size"], c["hidden_size"])
        self.LayerNorm = nn.LayerNorm(c["hidden_size"], eps=c.get("layer_norm_eps", 1e-5))

    def __call__(self, hidden, residual):
        return self.LayerNorm(self.dense(hidden) + residual)


class Layer(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.attention = Attention(c)
        self.intermediate = Intermediate(c)
        self.output = LayerOutput(c)

    def __call__(self, x, mask_bias):
        attn_out = self.attention(x, mask_bias)
        return self.output(self.intermediate(attn_out), attn_out)


class Encoder(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.layer = [Layer(c) for _ in range(c["num_hidden_layers"])]

    def __call__(self, x, mask_bias):
        for layer in self.layer:
            x = layer(x, mask_bias)
        return x


class ClassificationHead(nn.Module):
    def __init__(self, c):
        super().__init__()
        h = c["hidden_size"]
        self.dense = nn.Linear(h, h)
        self.out_proj = nn.Linear(h, c.get("num_labels", 1))

    def __call__(self, features):
        x = features[:, 0, :]
        x = mx.tanh(self.dense(x))
        return self.out_proj(x)


class XLMRModel(nn.Module):
    def __init__(self, c, has_classifier: bool):
        super().__init__()
        self.embeddings = Embeddings(c)
        self.encoder = Encoder(c)
        self.has_classifier = has_classifier
        if has_classifier:
            self.classifier = ClassificationHead(c)

    def __call__(self, input_ids, attention_mask):
        x = self.embeddings(input_ids, attention_mask)
        mask_bias = (1.0 - attention_mask.astype(x.dtype)) * mx.array(-1e4, dtype=x.dtype)
        mask_bias = mask_bias[:, None, None, :]
        x = self.encoder(x, mask_bias)
        if self.has_classifier:
            return self.classifier(x)
        return x


def load_xlmr(repo_id: str, has_classifier: bool):
    cfg_path = download_offline_first(repo_id, "config.json")
    tok_path = download_offline_first(repo_id, "tokenizer.json")
    weights_path = download_offline_first(repo_id, "model.safetensors")

    with open(cfg_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    tokenizer = Tokenizer.from_file(tok_path)
    model = XLMRModel(cfg, has_classifier=has_classifier)
    raw_weights = mx.load(weights_path)
    pre_quant = cfg.get("quantization")

    if pre_quant:
        q_bits = int(pre_quant.get("bits", 8))
        q_group = int(pre_quant.get("group_size", 64))
        quant_prefixes = set()
        for k in raw_weights.keys():
            nk = k[len("roberta."):] if k.startswith("roberta.") else k
            if nk.endswith(".scales"):
                quant_prefixes.add(nk[:-len(".scales")])
        nn.quantize(
            model,
            bits=q_bits,
            group_size=q_group,
            class_predicate=lambda path, m: path in quant_prefixes,
        )
        cleaned = []
        for k, v in raw_weights.items():
            nk = k[len("roberta."):] if k.startswith("roberta.") else k
            if nk.startswith("pooler.") or nk == "embeddings.position_ids":
                continue
            if not has_classifier and nk.startswith("classifier."):
                continue
            cleaned.append((nk, v))
        model.load_weights(cleaned, strict=True)
    else:
        cleaned = []
        for k, v in raw_weights.items():
            nk = k[len("roberta."):] if k.startswith("roberta.") else k
            if nk.startswith("pooler.") or nk == "embeddings.position_ids":
                continue
            if not has_classifier and nk.startswith("classifier."):
                continue
            cleaned.append((nk, v.astype(mx.float16)))
        model.load_weights(cleaned, strict=True)

    mx.eval(model.parameters())
    return model, tokenizer, cfg


class DocsInferenceEngine:
    def __init__(self, embed_repo: str, pooling: str, query_prefix: str, doc_prefix: str, rerank_repo: str | None):
        self.lock = threading.Lock()
        self.embed_repo = embed_repo
        self.pooling = pooling
        self.query_prefix = query_prefix
        self.doc_prefix = doc_prefix
        self.rerank_repo = rerank_repo

        print(f"Loading embedder: {embed_repo} (pooling={pooling})...", flush=True)
        self.embed_model, self.embed_tok, cfg = load_xlmr(embed_repo, has_classifier=False)
        self.embed_pad_id = int(cfg.get("pad_token_id", 1))
        self.dim = int(cfg["hidden_size"])
        # Warmup embedder
        _ = self.embed(["warmup"], input_type="query")
        print(f"Embedder ready (dim={self.dim})", flush=True)

        self.rerank_model = None
        self.rerank_tok = None
        self.rerank_pad_id = 1
        if rerank_repo:
            print(f"Loading reranker: {rerank_repo}...", flush=True)
            self.rerank_model, self.rerank_tok, rcfg = load_xlmr(rerank_repo, has_classifier=True)
            self.rerank_pad_id = int(rcfg.get("pad_token_id", 1))
            _ = self.rerank("warmup", ["warmup"], top_n=1)
            print("Reranker ready", flush=True)

    def embed(self, texts: list[str], input_type: str = "passage", max_length: int = 256, batch_size: int = 32) -> list[list[float]]:
        if not texts:
            return []
        prefix = self.query_prefix if input_type == "query" else self.doc_prefix
        prepared = [prefix + t for t in texts] if prefix else texts

        with self.lock:
            self.embed_tok.enable_truncation(max_length=max_length)
            self.embed_tok.no_padding()
            encs = self.embed_tok.encode_batch(prepared)
            order = sorted(range(len(encs)), key=lambda i: len(encs[i].ids))
            out = [None] * len(texts)
            for start in range(0, len(order), batch_size):
                idxs = order[start:start + batch_size]
                max_l = max(len(encs[i].ids) for i in idxs)
                pad_l = max(16, ((max_l + 15) // 16) * 16)
                ids = np.full((len(idxs), pad_l), self.embed_pad_id, dtype=np.int32)
                mask = np.zeros((len(idxs), pad_l), dtype=np.int32)
                for r, i in enumerate(idxs):
                    n = len(encs[i].ids)
                    ids[r, :n] = encs[i].ids
                    mask[r, :n] = 1
                m_ids = mx.array(ids)
                m_mask = mx.array(mask)
                h = self.embed_model(m_ids, m_mask).astype(mx.float32)
                if self.pooling == "cls":
                    vec = h[:, 0, :]
                else:
                    mf = m_mask[:, :, None].astype(mx.float32)
                    vec = mx.sum(h * mf, axis=1) / mx.maximum(mx.sum(mf, axis=1), 1e-9)
                norm = mx.sqrt(mx.maximum(mx.sum(vec * vec, axis=1, keepdims=True), 1e-12))
                vec = vec / norm
                mx.eval(vec)
                arr = np.array(vec, dtype=np.float32)
                for r, i in enumerate(idxs):
                    out[i] = arr[r].tolist()
            return out

    def rerank(self, query: str, documents: list[str], top_n: int = 30, max_length: int = 256, batch_size: int = 10) -> list[dict]:
        if self.rerank_model is None or not documents:
            return []
        with self.lock:
            self.rerank_tok.enable_truncation(max_length=max_length)
            self.rerank_tok.no_padding()
            encs = self.rerank_tok.encode_batch([(query, d) for d in documents])
            order = sorted(range(len(encs)), key=lambda i: len(encs[i].ids))
            scores = np.zeros(len(documents), dtype=np.float32)
            for start in range(0, len(order), batch_size):
                idxs = order[start:start + batch_size]
                max_l = max(len(encs[i].ids) for i in idxs)
                pad_l = max(16, ((max_l + 15) // 16) * 16)
                ids = np.full((len(idxs), pad_l), self.rerank_pad_id, dtype=np.int32)
                mask = np.zeros((len(idxs), pad_l), dtype=np.int32)
                for r, i in enumerate(idxs):
                    n = len(encs[i].ids)
                    ids[r, :n] = encs[i].ids
                    mask[r, :n] = 1
                logits = self.rerank_model(mx.array(ids), mx.array(mask)).astype(mx.float32)
                probs = mx.sigmoid(logits[:, 0])
                mx.eval(probs)
                vals = np.array(probs, dtype=np.float32)
                for r, i in enumerate(idxs):
                    scores[i] = vals[r]
        ranked = sorted(range(len(documents)), key=lambda i: (-float(scores[i]), i))[:max(1, min(top_n, len(documents)))]
        return [{"index": i, "relevance_score": float(scores[i])} for i in ranked]


def make_handler(engine: DocsInferenceEngine):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            return

        def _send_json(self, status: int, payload: dict):
            data = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/health":
                self._send_json(200, {
                    "status": "ok",
                    "embed_model": engine.embed_repo,
                    "rerank_model": engine.rerank_repo,
                    "rerank_ready": engine.rerank_model is not None,
                    "dim": engine.dim,
                })
            else:
                self._send_json(404, {"error": "not found"})

        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length) if length > 0 else b"{}"
                body = json.loads(raw.decode("utf-8"))
            except Exception as e:
                self._send_json(400, {"error": f"invalid json: {e}"})
                return

            if self.path == "/v1/embeddings":
                inp = body.get("input", "")
                if isinstance(inp, str):
                    texts = [inp]
                elif isinstance(inp, list):
                    texts = [str(x) for x in inp]
                else:
                    self._send_json(400, {"error": "input must be string or list of strings"})
                    return
                input_type = str(body.get("input_type", "passage"))
                try:
                    vecs = engine.embed(texts, input_type=input_type)
                    items = [{"object": "embedding", "index": i, "embedding": v} for i, v in enumerate(vecs)]
                    self._send_json(200, {"object": "list", "model": engine.embed_repo, "data": items})
                except Exception as e:
                    self._send_json(500, {"error": str(e)})
                return

            if self.path == "/v1/rerank":
                if engine.rerank_model is None:
                    self._send_json(503, {"error": "reranker not loaded"})
                    return
                query = str(body.get("query", ""))
                docs = body.get("documents", [])
                if not isinstance(docs, list):
                    self._send_json(400, {"error": "documents must be a list"})
                    return
                top_n = int(body.get("top_n", len(docs) or 1))
                try:
                    results = engine.rerank(query, [str(d) for d in docs], top_n=top_n)
                    self._send_json(200, {"model": engine.rerank_repo, "results": results})
                except Exception as e:
                    self._send_json(500, {"error": str(e)})
                return

            self._send_json(404, {"error": "not found"})

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--embed-model", required=True)
    parser.add_argument("--embed-pooling", choices=["cls", "mean"], default="cls")
    parser.add_argument("--query-prefix", default="")
    parser.add_argument("--doc-prefix", default="")
    parser.add_argument("--rerank-model", default=None)
    args = parser.parse_args()

    if args.host not in ("127.0.0.1", "::1", "localhost"):
        print(f"Refusing non-loopback bind host: {args.host}", file=sys.stderr, flush=True)
        sys.exit(2)

    engine = DocsInferenceEngine(
        embed_repo=args.embed_model,
        pooling=args.embed_pooling,
        query_prefix=args.query_prefix,
        doc_prefix=args.doc_prefix,
        rerank_repo=args.rerank_model,
    )
    server = ThreadingHTTPServer((args.host, args.port), make_handler(engine))

    def handle_stop(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)

    print(f"og Docs MLX server listening on http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
"""#
}
