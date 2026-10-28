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
// 入口:
//   /v1/review  添削（音声つき）。端末ごと FREE_PER_DAY 回
//   /v1/explain 直し 1 件を詳しく聞く（文字だけ・2026-10-13）。添削とは別に端末ごと EXPLAIN_PER_DAY 回・全体 EXPLAIN_GLOBAL_PER_DAY 回
//   /v1/scan    スクショ 1 枚から表現集の候補を取り出す（画像つき・2026-10-25）。端末ごと SCAN_PER_DAY 回・全体 SCAN_GLOBAL_PER_DAY 回
//   /v1/talk    「三人で話す」の 1 ターン（短い音声か文字・2026-10-28）。端末ごと TALK_PER_DAY 回・全体 TALK_GLOBAL_PER_DAY 回
//   /v1/voice   「三人で話す」の声（Sam とトラさんの読み上げ・文字だけ送って音声が返る・2026-10-28）。端末ごと VOICE_PER_DAY 回・全体 VOICE_GLOBAL_PER_DAY 回
//   /v1/quota   今日の回数（explain の分は "explain"、scan の分は "scan"、talk の分は "talk"、voice の分は "voice" に入れて返す）
//
// 月の予算（2026-10-13 本人「月に最大 1 万円程度に抑える」）:
//   1 回ごとに見込みの原価（REVIEW_COST_YEN / EXPLAIN_COST_YEN）を月の帳簿 m:YYYYMM に足し、MONTHLY_BUDGET_YEN に達したら止める。
//   日の上限（GLOBAL_PER_DAY・EXPLAIN_GLOBAL_PER_DAY）は、ある日に使い切られて月末まで止まるのを防ぐための分割
//
// 返事: Gemini の JSON そのまま＋ヘッダー X-Quota-Used / X-Quota-Limit
// 上限超え: 429 { "error": { "code": "quota", "used", "limit", "resetsAt" } }

const MODEL = 'gemini-3.6-flash';
const GEMINI = `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`;
// 三人で話すの声（TTS）。アプリの GeminiClient.voiceModel と揃える
const VOICE_MODEL = 'gemini-3.8-flash-lite-tts';
const GEMINI_VOICE = `https://generativelanguage.googleapis.com/v1beta/models/${VOICE_MODEL}:generateContent`;

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

// 日本時間の年月（YYYYMM）。月の予算の帳簿に使う
function jstMonth(now = new Date()) { return jstDay(now).slice(0, 6); }

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

    // 合言葉は APP_KEY（現行）と APP_KEY_OLD（入れ替え中の旧。配信中の旧版が更新されたら消す）のどちらか
    const presented = request.headers.get('x-app-key');
    const accepted = [env.APP_KEY, env.APP_KEY_OLD].filter((k) => k && k.length > 0);
    if (!presented || !accepted.includes(presented)) {
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

    const eLimit = Number(env.EXPLAIN_PER_DAY || '10');
    const eGlobalLimit = Number(env.EXPLAIN_GLOBAL_PER_DAY || '300');
    const eKey = `e:${device}:${day}`;
    const egKey = `ge:${day}`;

    const sLimit = Number(env.SCAN_PER_DAY || '20');
    const sGlobalLimit = Number(env.SCAN_GLOBAL_PER_DAY || '100');
    const sKey = `s:${device}:${day}`;
    const sgKey = `gs:${day}`;

    const tLimit = Number(env.TALK_PER_DAY || '40');
    const tGlobalLimit = Number(env.TALK_GLOBAL_PER_DAY || '300');
    const tKey = `t:${device}:${day}`;
    const tgKey = `gt:${day}`;

    const vLimit = Number(env.VOICE_PER_DAY || '60');
    const vGlobalLimit = Number(env.VOICE_GLOBAL_PER_DAY || '400');
    const vKey = `v:${device}:${day}`;
    const vgKey = `gv:${day}`;

    if (url.pathname === '/v1/quota' && request.method === 'GET') {
      const used = await count(env, dKey, ttl);
      const eUsed = await count(env, eKey, ttl);
      const sUsed = await count(env, sKey, ttl);
      const tUsed = await count(env, tKey, ttl);
      const vUsed = await count(env, vKey, ttl);
      return json({ used, limit, remaining: Math.max(0, limit - used), resetsInSeconds: ttl,
        explain: { used: eUsed, limit: eLimit, remaining: Math.max(0, eLimit - eUsed) },
        scan: { used: sUsed, limit: sLimit, remaining: Math.max(0, sLimit - sUsed) },
        talk: { used: tUsed, limit: tLimit, remaining: Math.max(0, tLimit - tUsed) },
        voice: { used: vUsed, limit: vLimit, remaining: Math.max(0, vLimit - vUsed) } });
    }

    const isExplain = url.pathname === '/v1/explain';
    const isScan = url.pathname === '/v1/scan';
    const isTalk = url.pathname === '/v1/talk';
    const isVoice = url.pathname === '/v1/voice';
    if ((url.pathname !== '/v1/review' && !isExplain && !isScan && !isTalk && !isVoice) || request.method !== 'POST') {
      return json({ error: { code: 'not_found', message: 'そのような入口はありません' } }, 404);
    }
    // 詳しく聞くは別の財布で数える（添削の 3 回を食わない）
    if (isExplain) {
      return relay(request, env, { dKey: eKey, gKey: egKey, ttl, limit: eLimit, globalLimit: eGlobalLimit,
        costYen: Number(env.EXPLAIN_COST_YEN || '1'),
        maxBody: Number(env.EXPLAIN_MAX_BODY_BYTES || '65536'), textOnly: true,
        quotaMessage: '今日の「詳しく聞く」の回数を使い切りました' });
    }
    // スクショから表現は画像 1 枚。これも別の財布（添削の 3 回を食わない）
    if (isScan) {
      return relay(request, env, { dKey: sKey, gKey: sgKey, ttl, limit: sLimit, globalLimit: sGlobalLimit,
        costYen: Number(env.SCAN_COST_YEN || '1'),
        maxBody: Number(env.SCAN_MAX_BODY_BYTES || '6000000'), textOnly: false,
        quotaMessage: '今日の「スクショから表現」の回数を使い切りました' });
    }
    // 三人で話すは 1 ターンごと（短い音声か文字だけ）。これも別の財布
    if (isTalk) {
      return relay(request, env, { dKey: tKey, gKey: tgKey, ttl, limit: tLimit, globalLimit: tGlobalLimit,
        costYen: Number(env.TALK_COST_YEN || '1'),
        maxBody: Number(env.TALK_MAX_BODY_BYTES || '3000000'), textOnly: false,
        quotaMessage: '今日の「三人で話す」の回数を使い切りました' });
    }
    // 三人で話すの声。送るのは文字だけ（音声は返ってくる側）。使い切ったらアプリは端末の声に落とす
    if (isVoice) {
      return relay(request, env, { dKey: vKey, gKey: vgKey, ttl, limit: vLimit, globalLimit: vGlobalLimit,
        costYen: Number(env.VOICE_COST_YEN || '1'),
        maxBody: Number(env.VOICE_MAX_BODY_BYTES || '32768'), textOnly: true, upstream: GEMINI_VOICE,
        quotaMessage: '今日の「三人で話す」の声の回数を使い切りました' });
    }
    return relay(request, env, { dKey, gKey, ttl, limit, globalLimit,
      costYen: Number(env.REVIEW_COST_YEN || '10'),
      maxBody: Number(env.MAX_BODY_BYTES || '8000000'), textOnly: false,
      quotaMessage: '今日の無料の回数を使い切りました' });
  },
};

// 回数を数えて Gemini に転送する（添削と詳しく聞くで共通）
async function relay(request, env, { dKey, gKey, ttl, limit, globalLimit, costYen, maxBody, textOnly, quotaMessage, upstream = GEMINI }) {
    const len = Number(request.headers.get('content-length') || '0');
    if (len > maxBody) return json({ error: { code: 'too_large', message: '音声が大きすぎます' } }, 413);

    const used = await count(env, dKey, ttl);
    if (used >= limit) {
      return json({ error: { code: 'quota', message: quotaMessage, used, limit, resetsInSeconds: ttl } }, 429,
        { 'x-quota-used': String(used), 'x-quota-limit': String(limit) });
    }
    // 月の予算。超えていたら全員止める（日付ではなく月が変わると戻る）
    const mKey = `m:${jstMonth()}`;
    const budget = Number(env.MONTHLY_BUDGET_YEN || '10000');
    const spent = Number((await env.QUOTA.get(mKey)) || '0');
    if (spent + costYen > budget) {
      return json({ error: { code: 'busy', message: '今月の無料の枠がいっぱいになりました。来月またどうぞ', resetsInSeconds: ttl } }, 503);
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
    // 詳しく聞くは文字だけ。音声や画像（inlineData / fileData）は通さない
    if (textOnly && JSON.stringify(parsed.contents).match(/"(inlineData|fileData)"/)) {
      return json({ error: { code: 'bad_request', message: '文字だけを送ってください' } }, 400);
    }

    // 先に数える（失敗しても 1 回と数える。同じ音声の送り直しは Gemini 側が落ちたときだけ戻す）
    const nowUsed = await bump(env, dKey, ttl);
    await bump(env, gKey, ttl);
    await env.QUOTA.put(mKey, String(spent + costYen), { expirationTtl: 40 * 86400 });

    let res;
    try {
      res = await fetch(upstream, {
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
}
