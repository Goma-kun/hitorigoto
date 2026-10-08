// 独り言アプリの中継サーバー（Cloudflare Worker）
//
// アプリは Gemini に送るのと同じ JSON（systemInstruction / contents / generationConfig）をここへ送る。
// ここで端末ごとの回数を数え、サーバーに置いた Gemini のキーを付けて Gemini に転送し、返事をそのまま返す。
// プロンプトはアプリ側にある（Prompts.swift が正本）。ここはプロンプトの中身を知らない。
//
// 守り:
//   - X-App-Key がアプリに埋めた値と一致しないものは弾く（本格的な不正対策は App Attest を後で足す）
//   - X-Device-Id（アプリが端末ごとに作る UUID）ごとに 1 日 FREE_PER_DAY 回まで
//   - 全体で 1 日 GLOBAL_PER_DAY 回まで（原価の天井）
//   - 本文は MAX_BODY_BYTES まで
//
// 返事: Gemini の JSON そのまま＋ヘッダー X-Quota-Used / X-Quota-Limit
// 上限超え: 429 { "error": { "code": "quota", "used", "limit", "resetsAt" } }

const MODEL = 'gemini-3.6-flash';
const GEMINI = `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`;

// 日本時間の日付（YYYYMMDD）。回数はこの単位で数える
function jstDay(now = new Date()) {
  const t = new Date(now.getTime() + 9 * 3600 * 1000);
  return t.toISOString().slice(0, 10).replace(/-/g, '');
}
// 次の 0 時（JST）まで何秒か。KV の期限に使う
function secondsToJstMidnight(now = new Date()) {
  const t = now.getTime() + 9 * 3600 * 1000;
  const next = Math.floor(t / 86400000 + 1) * 86400000;
  return Math.ceil((next - t) / 1000);
}

function json(obj, status = 200, headers = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', ...headers },
  });
}

async function count(env, key, ttl) {
  const v = Number((await env.QUOTA.get(key)) || '0');
  return v;
}
async function bump(env, key, ttl) {
  const v = Number((await env.QUOTA.get(key)) || '0') + 1;
  await env.QUOTA.put(key, String(v), { expirationTtl: Math.max(60, ttl) });
  return v;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health') return json({ ok: true, model: MODEL });

    if (!env.APP_KEY || request.headers.get('x-app-key') !== env.APP_KEY) {
      return json({ error: { code: 'forbidden', message: 'このアプリからの呼び出しではありません' } }, 403);
    }
    const device = (request.headers.get('x-device-id') || '').trim();
    if (!/^[0-9A-Fa-f-]{8,64}$/.test(device)) {
      return json({ error: { code: 'device', message: '端末の識別子がありません' } }, 400);
    }

    const day = jstDay();
    const ttl = secondsToJstMidnight();
    const limit = Number(env.FREE_PER_DAY || '3');
    const globalLimit = Number(env.GLOBAL_PER_DAY || '300');
    const dKey = `d:${device}:${day}`;
    const gKey = `g:${day}`;

    if (url.pathname === '/v1/quota' && request.method === 'GET') {
      const used = await count(env, dKey, ttl);
      return json({ used, limit, remaining: Math.max(0, limit - used), resetsInSeconds: ttl });
    }

    if (url.pathname !== '/v1/review' || request.method !== 'POST') {
      return json({ error: { code: 'not_found', message: 'そのような入口はありません' } }, 404);
    }

    const len = Number(request.headers.get('content-length') || '0');
    const maxBody = Number(env.MAX_BODY_BYTES || '8000000');
    if (len > maxBody) return json({ error: { code: 'too_large', message: '音声が大きすぎます' } }, 413);

    const used = await count(env, dKey, ttl);
    if (used >= limit) {
      return json({ error: { code: 'quota', message: '今日の無料の回数を使い切りました', used, limit, resetsInSeconds: ttl } }, 429,
        { 'x-quota-used': String(used), 'x-quota-limit': String(limit) });
    }
    const g = await count(env, gKey, ttl);
    if (g >= globalLimit) {
      return json({ error: { code: 'busy', message: '今日はアクセスが集中しています。明日またどうぞ', resetsInSeconds: ttl } }, 503);
    }

    let body;
    try { body = await request.text(); } catch { return json({ error: { code: 'bad_request', message: '本文が読めません' } }, 400); }
    if (body.length > maxBody) return json({ error: { code: 'too_large', message: '音声が大きすぎます' } }, 413);
    // 形だけ確かめる（中身はアプリが決める）。Gemini に渡してよい鍵だけ通す
    let parsed;
    try { parsed = JSON.parse(body); } catch { return json({ error: { code: 'bad_request', message: 'JSON ではありません' } }, 400); }
    const allowed = new Set(['systemInstruction', 'contents', 'generationConfig', 'tools']);
    for (const k of Object.keys(parsed)) if (!allowed.has(k)) delete parsed[k];
    if (!Array.isArray(parsed.contents)) return json({ error: { code: 'bad_request', message: 'contents がありません' } }, 400);

    // 先に数える（失敗しても 1 回と数える。同じ音声の送り直しは Gemini 側が落ちたときだけ戻す）
    const nowUsed = await bump(env, dKey, ttl);
    await bump(env, gKey, ttl);

    let res;
    try {
      res = await fetch(GEMINI, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY },
        body: JSON.stringify(parsed),
      });
    } catch (e) {
      // こちら側の通信失敗は回数に数えない
      await env.QUOTA.put(dKey, String(nowUsed - 1), { expirationTtl: Math.max(60, ttl) });
      return json({ error: { code: 'upstream', message: 'AI に届きませんでした: ' + (e && e.message || '') } }, 502);
    }
    const text = await res.text();
    if (res.status >= 500 || res.status === 429) {
      await env.QUOTA.put(dKey, String(nowUsed - 1), { expirationTtl: Math.max(60, ttl) });
    }
    return new Response(text, {
      status: res.status,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'x-quota-used': String(nowUsed),
        'x-quota-limit': String(limit),
      },
    });
  },
};
