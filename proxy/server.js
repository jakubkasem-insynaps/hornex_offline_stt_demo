// STT proxy: holds provider API keys and forwards audio. Zero npm dependencies
// (Node 22+). Run with:  node server.js
//
//   GET  /health                    liveness + which engines have a key
//   GET  /v1/engines                engine list for the app's online picker
//   POST /v1/transcribe?engine=ID   body = audio bytes (Content-Type: audio/wav)
//   POST /v1/summarize              body = {"text": "..."}  (optional stretch feature)
//   GET  /models/<id>/<file>        serves locally converted models to the app
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { listEngines, UpstreamError } from './engines.js';

const here = path.dirname(fileURLToPath(import.meta.url));
try {
  process.loadEnvFile(path.join(here, '.env'));
} catch {
  // No .env file: rely on the real environment.
}

const MAX_BODY = Number(process.env.MAX_BODY_BYTES || 200 * 1024 * 1024);
const modelsDir = () => path.resolve(here, process.env.MODELS_DIR || '../models_out');

function send(res, status, body, headers = {}) {
  const data = Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length, ...headers });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new UpstreamError('Body too large', { status: 413, retryable: false }));
        req.destroy();
      } else chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function publicEngine(e) {
  return {
    id: e.id, provider: e.provider, displayName: e.displayName, model: e.model,
    configured: e.configured, baseUrl: e.baseUrl, notes: e.notes, unverified: e.unverified ?? null,
  };
}

async function transcribe(req, res, url) {
  const id = url.searchParams.get('engine');
  const engine = listEngines().find((e) => e.id === id);
  if (!engine) return send(res, 404, { error: `Unknown engine "${id}"`, retryable: false });
  if (!engine.configured) return send(res, 503, { error: `${engine.keyEnv} is not set on the proxy`, retryable: false });
  const bytes = await readBody(req);
  if (bytes.length === 0) return send(res, 400, { error: 'Empty audio body', retryable: false });
  const contentType = (req.headers['content-type'] || 'audio/wav').split(';')[0].trim();
  const ext = { 'audio/wav': 'wav', 'audio/x-wav': 'wav', 'audio/ogg': 'ogg', 'audio/opus': 'opus', 'audio/flac': 'flac', 'audio/mpeg': 'mp3' }[contentType] || 'wav';
  const started = performance.now();
  const out = await engine.run({ bytes, contentType, filename: `audio.${ext}` }, engine);
  const providerMs = Math.round(performance.now() - started);
  console.log(`[transcribe] ${engine.id} ${bytes.length} bytes -> ${out.text.length} chars in ${providerMs} ms`);
  send(res, 200, {
    text: out.text, engine: engine.id, provider: engine.provider, model: engine.model,
    language: 'sk', providerMs, baseUrl: engine.baseUrl, meta: out.meta ?? {},
  });
}

// Optional: summarise a transcript with one of the already-listed providers.
// No default model on purpose: set SUMMARY_PROVIDER (openai|gemini) and SUMMARY_MODEL.
async function summarize(req, res) {
  const provider = process.env.SUMMARY_PROVIDER;
  const model = process.env.SUMMARY_MODEL;
  if (!provider || !model) return send(res, 503, { error: 'Set SUMMARY_PROVIDER and SUMMARY_MODEL on the proxy to enable summaries', retryable: false });
  const { text } = JSON.parse((await readBody(req)).toString('utf8') || '{}');
  if (!text) return send(res, 400, { error: 'Missing "text"', retryable: false });
  const prompt = `Zhrň nasledujúci prepis nahrávky v slovenčine do niekoľkých stručných bodov. Nepridávaj nič, čo v prepise nie je.\n\nPrepis:\n${text}`;
  const started = performance.now();
  let summary;
  if (provider === 'openai') {
    const r = await fetch(`${process.env.OPENAI_BASE_URL || 'https://api.openai.com'}/v1/chat/completions`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.OPENAI_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, messages: [{ role: 'user', content: prompt }] }),
    });
    if (!r.ok) throw new UpstreamError(`OpenAI summary: HTTP ${r.status}`, { detail: (await r.text()).slice(0, 1000) });
    summary = (await r.json()).choices?.[0]?.message?.content ?? '';
  } else if (provider === 'gemini') {
    const r = await fetch(`${process.env.GEMINI_BASE_URL || 'https://generativelanguage.googleapis.com'}/v1beta/interactions`, {
      method: 'POST',
      headers: { 'x-goog-api-key': process.env.GEMINI_API_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, input: [{ type: 'text', text: prompt }] }),
    });
    if (!r.ok) throw new UpstreamError(`Gemini summary: HTTP ${r.status}`, { detail: (await r.text()).slice(0, 1000) });
    summary = (await r.json()).output_text ?? '';
  } else {
    return send(res, 503, { error: `Unknown SUMMARY_PROVIDER "${provider}"`, retryable: false });
  }
  send(res, 200, { summary: summary.trim(), provider, model, providerMs: Math.round(performance.now() - started) });
}

function serveModel(req, res, url) {
  const root = modelsDir();
  const file = path.resolve(root, decodeURIComponent(url.pathname.slice('/models/'.length)));
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
    return send(res, 404, { error: 'No such model file', retryable: false });
  }
  const size = fs.statSync(file).size;
  const type = file.endsWith('.json') ? 'application/json' : file.endsWith('.txt') ? 'text/plain; charset=utf-8' : 'application/octet-stream';
  const range = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range || '');
  if (range) {
    const start = Number(range[1]);
    const end = range[2] ? Math.min(Number(range[2]), size - 1) : size - 1;
    if (start >= size) return send(res, 416, { error: 'Range not satisfiable' }, { 'Content-Range': `bytes */${size}` });
    res.writeHead(206, { 'Content-Type': type, 'Content-Length': end - start + 1, 'Content-Range': `bytes ${start}-${end}/${size}`, 'Accept-Ranges': 'bytes' });
    return fs.createReadStream(file, { start, end }).pipe(res);
  }
  res.writeHead(200, { 'Content-Type': type, 'Content-Length': size, 'Accept-Ranges': 'bytes' });
  fs.createReadStream(file).pipe(res);
}

export function createServer() {
  return http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://proxy');
    try {
      if (req.method === 'GET' && url.pathname === '/health') {
        // Unauthenticated on purpose: the app uses it as its "is online" probe.
        return send(res, 200, { ok: true, time: new Date().toISOString() });
      }
      const token = process.env.PROXY_TOKEN;
      if (token && req.headers['x-proxy-token'] !== token) {
        return send(res, 401, { error: 'Missing or wrong x-proxy-token', retryable: false });
      }
      if (req.method === 'GET' && url.pathname === '/v1/engines') {
        return send(res, 200, { engines: listEngines().map(publicEngine) });
      }
      if (req.method === 'POST' && url.pathname === '/v1/transcribe') return await transcribe(req, res, url);
      if (req.method === 'POST' && url.pathname === '/v1/summarize') return await summarize(req, res);
      if (req.method === 'GET' && url.pathname.startsWith('/models/')) return serveModel(req, res, url);
      send(res, 404, { error: 'Not found', retryable: false });
    } catch (e) {
      const status = e instanceof UpstreamError ? e.status : 500;
      console.error(`[error] ${req.method} ${url.pathname}: ${e.message}${e.detail ? `\n  ${e.detail}` : ''}`);
      if (!res.headersSent) send(res, status, { error: e.message, detail: e.detail ?? null, retryable: e instanceof UpstreamError ? e.retryable : false });
      else res.destroy();
    }
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT || 8787);
  const host = process.env.HOST || '0.0.0.0';
  createServer().listen(port, host, () => {
    console.log(`STT proxy listening on http://${host}:${port}`);
    console.log(`Serving converted models from ${modelsDir()}`);
    if (!process.env.PROXY_TOKEN) console.log('WARNING: PROXY_TOKEN is not set; anyone who can reach this port can spend your provider credits.');
    for (const e of listEngines()) console.log(`  ${e.configured ? 'ready  ' : 'no key '} ${e.id} (${e.model})`);
  });
}
