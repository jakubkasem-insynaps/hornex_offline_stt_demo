// Tests the proxy against fake upstreams that follow each provider's documented
// request/response shape. They prove the proxy sends what the docs describe;
// they do not prove the real providers accept it.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const seen = [];
const upstream = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const url = new URL(req.url, 'http://x');
    seen.push({ method: req.method, path: url.pathname, query: url.search, headers: req.headers, body: body.toString('latin1') });
    const json = (status, obj) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
    const p = url.pathname;
    // Soniox
    if (req.method === 'POST' && p === '/v1/files') return json(201, { id: 'file1' });
    if (req.method === 'POST' && p === '/v1/transcriptions') return json(201, { id: 'tr1', status: 'queued' });
    if (req.method === 'GET' && p === '/v1/transcriptions/tr1') return json(200, { id: 'tr1', status: 'completed' });
    if (req.method === 'GET' && p === '/v1/transcriptions/tr1/transcript') return json(200, { id: 'tr1', text: 'soniox text', tokens: [] });
    if (req.method === 'DELETE') return json(204, {});
    // ElevenLabs
    if (p === '/v1/speech-to-text') return json(200, { language_code: 'slk', text: 'eleven text', words: [] });
    // Speechmatics
    if (req.method === 'POST' && p === '/v2/jobs') return json(201, { id: 'job1' });
    if (req.method === 'GET' && p === '/v2/jobs/job1') return json(200, { job: { id: 'job1', status: 'done' } });
    if (p === '/v2/jobs/job1/transcript') { res.writeHead(200, { 'Content-Type': 'text/plain' }); return res.end('speechmatics text\n'); }
    // OpenAI
    if (p === '/v1/audio/transcriptions') return json(200, { text: 'openai text' });
    // Gemini
    if (p === '/v1beta/interactions') return json(200, { output_text: 'gemini text' });
    // Deepgram
    if (p === '/v1/listen') return json(200, { metadata: { request_id: 'r1' }, results: { channels: [{ alternatives: [{ transcript: 'deepgram text' }] }] } });
    if (p === '/fail') return json(500, { error: 'boom' });
    json(404, { error: 'unexpected', path: p });
  });
});

let proxy, base, modelsRoot;

test.before(async () => {
  await new Promise((r) => upstream.listen(0, '127.0.0.1', r));
  const up = `http://127.0.0.1:${upstream.address().port}`;
  modelsRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'models-'));
  fs.mkdirSync(path.join(modelsRoot, 'm1'));
  fs.writeFileSync(path.join(modelsRoot, 'm1', 'tokens.txt'), '0123456789');
  Object.assign(process.env, {
    ENABLE_MOCK: '1', MOCK_DELAY_MS: '0', PROXY_TOKEN: 'secret', MODELS_DIR: modelsRoot,
    SONIOX_API_KEY: 'k-soniox', SONIOX_BASE_URL: up,
    ELEVENLABS_API_KEY: 'k-eleven', ELEVENLABS_BASE_URL: up,
    SPEECHMATICS_API_KEY: 'k-sm', SPEECHMATICS_BASE_URL: up,
    OPENAI_API_KEY: 'k-openai', OPENAI_BASE_URL: up,
    GEMINI_API_KEY: 'k-gemini', GEMINI_BASE_URL: up,
    DEEPGRAM_BASE_URL: up,
  });
  delete process.env.DEEPGRAM_API_KEY;
  const { createServer } = await import('./server.js');
  proxy = createServer();
  await new Promise((r) => proxy.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${proxy.address().port}`;
});

test.after(() => { proxy.close(); upstream.close(); fs.rmSync(modelsRoot, { recursive: true, force: true }); });

const auth = { 'x-proxy-token': 'secret' };
const wav = Buffer.from('RIFF....WAVEfake');
const post = (engine) => fetch(`${base}/v1/transcribe?engine=${engine}`, { method: 'POST', headers: { ...auth, 'Content-Type': 'audio/wav' }, body: wav });
const last = (p, method) => seen.findLast((r) => r.path === p && (!method || r.method === method));

test('health is open, everything else needs the token', async () => {
  assert.equal((await fetch(`${base}/health`)).status, 200);
  assert.equal((await fetch(`${base}/v1/engines`)).status, 401);
  assert.equal((await fetch(`${base}/v1/transcribe?engine=mock`, { method: 'POST', body: wav })).status, 401);
});

test('engine list reports which engines have a key and never leaks keys', async () => {
  const r = await fetch(`${base}/v1/engines`, { headers: auth });
  const text = await r.text();
  const { engines } = JSON.parse(text);
  assert.equal(engines.find((e) => e.id === 'soniox-async').configured, true);
  assert.equal(engines.find((e) => e.id === 'deepgram-nova-3').configured, false);
  assert.ok(!text.includes('k-soniox') && !text.includes('k-openai'));
});

test('mock engine round trip', async () => {
  const r = await post('mock');
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.match(j.text, /skúšobný/);
  assert.equal(j.language, 'sk');
  assert.equal(typeof j.providerMs, 'number');
});

test('soniox: upload, create with strict Slovak hint, poll, fetch, clean up', async () => {
  const j = await (await post('soniox-async')).json();
  assert.equal(j.text, 'soniox text');
  assert.equal(last('/v1/files', 'POST').headers.authorization, 'Bearer k-soniox');
  const create = JSON.parse(last('/v1/transcriptions', 'POST').body);
  assert.deepEqual(create, { model: 'stt-async-v6', file_id: 'file1', language_hints: ['sk'], language_hints_strict: true });
  await new Promise((r) => setTimeout(r, 50));
  assert.ok(last('/v1/files/file1', 'DELETE'));
});

test('elevenlabs: model_id and language_code in the form', async () => {
  const j = await (await post('elevenlabs-scribe-v2')).json();
  assert.equal(j.text, 'eleven text');
  const req = last('/v1/speech-to-text');
  assert.equal(req.headers['xi-api-key'], 'k-eleven');
  assert.match(req.body, /name="model_id"\r\n\r\nscribe_v2/);
  assert.match(req.body, /name="language_code"\r\n\r\nsk/);
  assert.match(req.body, /name="file"; filename="audio.wav"/);
});

test('speechmatics: enhanced Slovak job, plain-text transcript', async () => {
  const j = await (await post('speechmatics-enhanced')).json();
  assert.equal(j.text, 'speechmatics text');
  const req = last('/v2/jobs', 'POST');
  assert.equal(req.headers.authorization, 'Bearer k-sm');
  assert.ok(req.body.includes('{"type":"transcription","transcription_config":{"language":"sk","model":"enhanced"}}'));
  assert.equal(last('/v2/jobs/job1/transcript').query, '?format=txt');
});

test('openai: singular language for gpt-4o-transcribe, array for gpt-transcribe', async () => {
  assert.equal((await (await post('openai-gpt-4o-transcribe')).json()).text, 'openai text');
  let body = last('/v1/audio/transcriptions').body;
  assert.match(body, /name="model"\r\n\r\ngpt-4o-transcribe/);
  assert.match(body, /name="language"\r\n\r\nsk/);
  await post('openai-gpt-transcribe');
  body = last('/v1/audio/transcriptions').body;
  assert.match(body, /name="model"\r\n\r\ngpt-transcribe/);
  assert.match(body, /name="languages\[\]"\r\n\r\nsk/);
  assert.doesNotMatch(body, /name="language"\r\n/);
});

test('gemini: inline base64 audio with sk-SK', async () => {
  assert.equal((await (await post('gemini-transcribe')).json()).text, 'gemini text');
  const req = last('/v1beta/interactions');
  assert.equal(req.headers['x-goog-api-key'], 'k-gemini');
  const body = JSON.parse(req.body);
  assert.equal(body.model, 'models/gemini-3.5-transcribe');
  assert.equal(body.input[0].data, wav.toString('base64'));
  assert.deepEqual(body.generation_config.transcription_config.language_codes, ['sk-SK']);
});

test('engine without a key returns 503, unknown engine 404, empty body 400', async () => {
  assert.equal((await post('deepgram-nova-3')).status, 503);
  assert.equal((await post('nope')).status, 404);
  const r = await fetch(`${base}/v1/transcribe?engine=mock`, { method: 'POST', headers: auth });
  assert.equal(r.status, 400);
});

test('deepgram: raw body, Token auth, forced language', async () => {
  process.env.DEEPGRAM_API_KEY = 'k-dg';
  const j = await (await post('deepgram-nova-3')).json();
  assert.equal(j.text, 'deepgram text');
  const req = last('/v1/listen');
  assert.equal(req.headers.authorization, 'Token k-dg');
  assert.equal(req.query, '?model=nova-3&language=sk&smart_format=true');
  assert.equal(req.body, wav.toString('latin1'));
});

test('upstream failure maps to a retryable 502', async () => {
  process.env.DEEPGRAM_BASE_URL = `http://127.0.0.1:${upstream.address().port}/fail?`;
  const r = await post('deepgram-nova-3');
  assert.equal(r.status, 502);
  assert.equal((await r.json()).retryable, true);
});

test('model files: served with range support, no path traversal', async () => {
  const full = await fetch(`${base}/models/m1/tokens.txt`, { headers: auth });
  assert.equal(await full.text(), '0123456789');
  const part = await fetch(`${base}/models/m1/tokens.txt`, { headers: { ...auth, Range: 'bytes=4-' } });
  assert.equal(part.status, 206);
  assert.equal(await part.text(), '456789');
  assert.equal((await fetch(`${base}/models/..%2F..%2Fserver.js`, { headers: auth })).status, 404);
  assert.equal((await fetch(`${base}/models/m1/missing.onnx`, { headers: auth })).status, 404);
});

test('summaries are off until a model is configured', async () => {
  const r = await fetch(`${base}/v1/summarize`, { method: 'POST', headers: auth, body: JSON.stringify({ text: 'x' }) });
  assert.equal(r.status, 503);
});
