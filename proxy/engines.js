// Cloud STT engines. One entry per (provider, model) the app can pick.
//
// Model IDs, endpoints and field names were checked against each provider's
// docs on 2026-11-12. They change; every model ID and base URL can be
// overridden from .env without touching code. Items the docs did not let us
// confirm are flagged with `unverified` and shown in the app.
//
// Language is always forced to Slovak. Never rely on auto-detection.

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class UpstreamError extends Error {
  constructor(message, { status = 502, retryable = true, detail } = {}) {
    super(message);
    this.status = status;
    this.retryable = retryable;
    this.detail = detail;
  }
}

async function call(url, init, what) {
  let res;
  try {
    res = await fetch(url, { ...init, signal: AbortSignal.timeout(init?.timeoutMs ?? 120_000) });
  } catch (e) {
    throw new UpstreamError(`${what}: ${e.name === 'TimeoutError' ? 'timed out' : e.message}`, { status: 504 });
  }
  const body = await res.text();
  if (!res.ok) {
    throw new UpstreamError(`${what}: HTTP ${res.status}`, {
      status: 502,
      retryable: res.status >= 500 || res.status === 429 || res.status === 408,
      detail: body.slice(0, 2000),
    });
  }
  return body;
}

async function callJson(url, init, what) {
  const body = await call(url, init, what);
  try {
    return JSON.parse(body);
  } catch {
    throw new UpstreamError(`${what}: response was not JSON`, { detail: body.slice(0, 500) });
  }
}

function fileForm(fields, fileField, audio) {
  const form = new FormData();
  for (const [k, v] of Object.entries(fields)) form.append(k, v);
  form.append(fileField, new Blob([audio.bytes], { type: audio.contentType }), audio.filename);
  return form;
}

const env = (name, fallback) => process.env[name] || fallback;

// ---------------------------------------------------------------- Soniox
// Async flow: upload file -> create transcription -> poll -> fetch transcript.
// EU: set SONIOX_BASE_URL=https://api.eu.soniox.com (region access is requested
// in the Soniox console; an EU project has its own key).
async function soniox(audio, { model }) {
  const base = env('SONIOX_BASE_URL', 'https://api.soniox.com');
  const auth = { Authorization: `Bearer ${process.env.SONIOX_API_KEY}` };
  const file = await callJson(`${base}/v1/files`, { method: 'POST', headers: auth, body: fileForm({}, 'file', audio) }, 'Soniox upload');
  let jobId;
  try {
    const job = await callJson(`${base}/v1/transcriptions`, {
      method: 'POST',
      headers: { ...auth, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, file_id: file.id, language_hints: ['sk'], language_hints_strict: true }),
    }, 'Soniox create transcription');
    jobId = job.id;
    const deadline = Date.now() + 180_000;
    for (let status = job.status; status !== 'completed'; ) {
      if (status === 'error') throw new UpstreamError('Soniox transcription failed', { retryable: false, detail: JSON.stringify(job) });
      if (Date.now() > deadline) throw new UpstreamError('Soniox transcription timed out', { status: 504 });
      await sleep(400);
      const s = await callJson(`${base}/v1/transcriptions/${jobId}`, { headers: auth }, 'Soniox poll');
      if (s.status === 'error') throw new UpstreamError(`Soniox transcription failed: ${s.error_message ?? ''}`, { retryable: false, detail: JSON.stringify(s) });
      status = s.status;
    }
    const t = await callJson(`${base}/v1/transcriptions/${jobId}/transcript`, { headers: auth }, 'Soniox transcript');
    return { text: t.text ?? '', meta: { transcriptionId: jobId } };
  } finally {
    // Best-effort cleanup so audio does not linger at the provider.
    if (jobId) fetch(`${base}/v1/transcriptions/${jobId}`, { method: 'DELETE', headers: auth }).catch(() => {});
    fetch(`${base}/v1/files/${file.id}`, { method: 'DELETE', headers: auth }).catch(() => {});
  }
}

// ---------------------------------------------------------------- ElevenLabs
// Synchronous. EU residency (ELEVENLABS_BASE_URL=https://api.eu.residency.elevenlabs.io)
// is Enterprise-only with a separate workspace and key.
async function elevenlabs(audio, { model }) {
  const base = env('ELEVENLABS_BASE_URL', 'https://api.elevenlabs.io');
  const r = await callJson(`${base}/v1/speech-to-text`, {
    method: 'POST',
    headers: { 'xi-api-key': process.env.ELEVENLABS_API_KEY },
    body: fileForm({ model_id: model, language_code: 'sk' }, 'file', audio),
  }, 'ElevenLabs');
  return { text: r.text ?? '', meta: { languageCode: r.language_code, languageProbability: r.language_probability } };
}

// ---------------------------------------------------------------- Speechmatics
// Batch jobs API. Default host is the EU one (eu1), available to all customers.
async function speechmatics(audio, { model }) {
  const base = env('SPEECHMATICS_BASE_URL', 'https://eu1.asr.api.speechmatics.com');
  const auth = { Authorization: `Bearer ${process.env.SPEECHMATICS_API_KEY}` };
  const config = JSON.stringify({ type: 'transcription', transcription_config: { language: 'sk', model } });
  const job = await callJson(`${base}/v2/jobs`, { method: 'POST', headers: auth, body: fileForm({ config }, 'data_file', audio) }, 'Speechmatics create job');
  const deadline = Date.now() + 180_000;
  for (;;) {
    const s = await callJson(`${base}/v2/jobs/${job.id}`, { headers: auth }, 'Speechmatics poll');
    const status = s.job?.status;
    if (status === 'done') break;
    if (status !== 'running') throw new UpstreamError(`Speechmatics job ${status}`, { retryable: false, detail: JSON.stringify(s) });
    if (Date.now() > deadline) throw new UpstreamError('Speechmatics job timed out', { status: 504 });
    await sleep(500);
  }
  const text = await call(`${base}/v2/jobs/${job.id}/transcript?format=txt`, { headers: auth }, 'Speechmatics transcript');
  fetch(`${base}/v2/jobs/${job.id}`, { method: 'DELETE', headers: auth }).catch(() => {});
  return { text: text.trim(), meta: { jobId: job.id } };
}

// ---------------------------------------------------------------- OpenAI
// gpt-4o-transcribe takes `language`; its successor gpt-transcribe takes a
// `languages` array instead and rejects the singular form.
// EU residency (OPENAI_BASE_URL=https://eu.api.openai.com) needs sales approval.
async function openai(audio, { model, languageParam }) {
  const base = env('OPENAI_BASE_URL', 'https://api.openai.com');
  const fields = { model };
  if (languageParam === 'languages[]') fields['languages[]'] = 'sk';
  else Object.assign(fields, { language: 'sk', response_format: 'json' });
  const r = await callJson(`${base}/v1/audio/transcriptions`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.OPENAI_API_KEY}` },
    body: fileForm(fields, 'file', audio),
  }, 'OpenAI');
  return { text: r.text ?? '', meta: {} };
}

// ---------------------------------------------------------------- Gemini
// Interactions API with inline base64 audio. The docs say the transcribe model
// accepts inline audio but show no schema for it, so this request shape is
// inferred from the general audio example. Treat as experimental.
async function gemini(audio, { model }) {
  const base = env('GEMINI_BASE_URL', 'https://generativelanguage.googleapis.com');
  const r = await callJson(`${base}/v1beta/interactions`, {
    method: 'POST',
    headers: { 'x-goog-api-key': process.env.GEMINI_API_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: model.startsWith('models/') ? model : `models/${model}`,
      input: [{ type: 'audio', data: Buffer.from(audio.bytes).toString('base64'), mime_type: audio.contentType }],
      generation_config: { transcription_config: { language_codes: ['sk-SK'] } },
    }),
  }, 'Gemini');
  return { text: (r.output_text ?? '').trim(), meta: {} };
}

// ---------------------------------------------------------------- Deepgram
// Synchronous, raw audio body. EU: DEEPGRAM_BASE_URL=https://api.eu.deepgram.com (same key).
async function deepgram(audio, { model }) {
  const base = env('DEEPGRAM_BASE_URL', 'https://api.deepgram.com');
  const r = await callJson(`${base}/v1/listen?model=${encodeURIComponent(model)}&language=sk&smart_format=true`, {
    method: 'POST',
    headers: { Authorization: `Token ${process.env.DEEPGRAM_API_KEY}`, 'Content-Type': audio.contentType },
    body: audio.bytes,
  }, 'Deepgram');
  return { text: r.results?.channels?.[0]?.alternatives?.[0]?.transcript ?? '', meta: { requestId: r.metadata?.request_id } };
}

// ---------------------------------------------------------------- Mock
// Enabled with ENABLE_MOCK=1. Lets the app and the tests run without any key.
async function mock(audio) {
  await sleep(Number(env('MOCK_DELAY_MS', '150')));
  return { text: env('MOCK_TEXT', 'Toto je skúšobný prepis z falošného poskytovateľa.'), meta: { bytes: audio.bytes.length } };
}

export function listEngines() {
  const engines = [
    {
      id: 'soniox-async', provider: 'Soniox', displayName: 'Soniox async',
      model: env('SONIOX_ASYNC_MODEL', 'stt-async-v6'), keyEnv: 'SONIOX_API_KEY',
      baseUrlEnv: 'SONIOX_BASE_URL', defaultBaseUrl: 'https://api.soniox.com', run: soniox,
      notes: 'Batch (files + transcriptions API). EU endpoint on request. Realtime model stt-rt-v6 is not wired up.',
    },
    {
      id: 'elevenlabs-scribe-v2', provider: 'ElevenLabs', displayName: 'ElevenLabs Scribe v2',
      model: env('ELEVENLABS_V2_MODEL', 'scribe_v2'), keyEnv: 'ELEVENLABS_API_KEY',
      baseUrlEnv: 'ELEVENLABS_BASE_URL', defaultBaseUrl: 'https://api.elevenlabs.io', run: elevenlabs,
      notes: 'Batch. EU residency is Enterprise-only. Realtime (scribe_v2_realtime) is not wired up.',
    },
    {
      id: 'elevenlabs-scribe-v3', provider: 'ElevenLabs', displayName: 'ElevenLabs Scribe v3',
      model: env('ELEVENLABS_V3_MODEL', 'scribe_v3'), keyEnv: 'ELEVENLABS_API_KEY',
      baseUrlEnv: 'ELEVENLABS_BASE_URL', defaultBaseUrl: 'https://api.elevenlabs.io', run: elevenlabs,
      notes: 'Batch. Newer than the requested v2; added for comparison.',
      unverified: 'Slovak support on Scribe v3 is not stated explicitly in the docs ("90+ languages").',
    },
    {
      id: 'speechmatics-enhanced', provider: 'Speechmatics', displayName: 'Speechmatics enhanced',
      model: env('SPEECHMATICS_MODEL', 'enhanced'), keyEnv: 'SPEECHMATICS_API_KEY',
      baseUrlEnv: 'SPEECHMATICS_BASE_URL', defaultBaseUrl: 'https://eu1.asr.api.speechmatics.com', run: speechmatics,
      notes: 'Batch jobs API on the EU host (eu1) by default.',
    },
    {
      id: 'openai-gpt-4o-transcribe', provider: 'OpenAI', displayName: 'OpenAI gpt-4o-transcribe',
      model: env('OPENAI_4O_MODEL', 'gpt-4o-transcribe'), keyEnv: 'OPENAI_API_KEY', languageParam: 'language',
      baseUrlEnv: 'OPENAI_BASE_URL', defaultBaseUrl: 'https://api.openai.com', run: openai,
      notes: 'Deprecated by OpenAI; shutdown announced for 2027-02-26. 25 MB upload limit.',
    },
    {
      id: 'openai-gpt-transcribe', provider: 'OpenAI', displayName: 'OpenAI gpt-transcribe',
      model: env('OPENAI_MODEL', 'gpt-transcribe'), keyEnv: 'OPENAI_API_KEY', languageParam: 'languages[]',
      baseUrlEnv: 'OPENAI_BASE_URL', defaultBaseUrl: 'https://api.openai.com', run: openai,
      notes: 'Successor to gpt-4o-transcribe. 25 MB upload limit.',
      unverified: 'Multipart spelling of the `languages` array ("languages[]") and Slovak support are not confirmed in the docs.',
    },
    {
      id: 'gemini-transcribe', provider: 'Google', displayName: 'Gemini transcribe',
      model: env('GEMINI_MODEL', 'gemini-3.5-transcribe'), keyEnv: 'GEMINI_API_KEY',
      baseUrlEnv: 'GEMINI_BASE_URL', defaultBaseUrl: 'https://generativelanguage.googleapis.com', run: gemini,
      notes: 'Optional. Inline audio, about 20 MB request limit. No data-residency information in the docs.',
      unverified: 'Inline-audio request shape for the transcribe model is inferred, not documented.',
    },
    {
      id: 'deepgram-nova-3', provider: 'Deepgram', displayName: 'Deepgram Nova-3',
      model: env('DEEPGRAM_MODEL', 'nova-3'), keyEnv: 'DEEPGRAM_API_KEY',
      baseUrlEnv: 'DEEPGRAM_BASE_URL', defaultBaseUrl: 'https://api.deepgram.com', run: deepgram,
      notes: 'Optional baseline. EU endpoint api.eu.deepgram.com uses the same key.',
    },
  ];
  if (process.env.ENABLE_MOCK === '1') {
    engines.push({ id: 'mock', provider: 'Mock', displayName: 'Mock (no provider)', model: 'mock', keyEnv: null, run: mock, notes: 'Returns a fixed Slovak sentence. For testing the app without keys.' });
  }
  return engines.map((e) => ({
    ...e,
    configured: e.keyEnv === null || Boolean(process.env[e.keyEnv]),
    baseUrl: e.baseUrlEnv ? env(e.baseUrlEnv, e.defaultBaseUrl) : null,
  }));
}

export { UpstreamError };
