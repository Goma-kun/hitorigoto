// ============================================================
// 履歴層。storage のキーと保存・読み出し・エクスポート／インポートをここに集約する。
// 独り言のデータ（en_ 接頭辞）はまもるくん時代と同じキー・同じ形を使う。
// エクスポート形式もまもるくんの mamorukun-english-v1 と互換にしてあり、
// まもるくんから書き出した JSON をそのまま読み込める
// ============================================================
const HistoryStore = (() => {
  const KEYS = {
    transcript:  'hg_transcript',   // 録音中の書き起こし（クラッシュ対策の一時保存）
    enSessions:  'en_sessions',     // セッション履歴
    enRecurring: 'en_recurring',    // 繰り返し指摘
  };

  const EXPORT_FORMAT = 'hitorigoto-english-v1';
  // まもるくんの独り言モードから書き出した JSON も同じ形なので受け付ける
  const IMPORT_FORMATS = ['hitorigoto-english-v1', 'mamorukun-english-v1'];

  async function load() {
    const d = await chrome.storage.local.get(Object.values(KEYS));
    return {
      transcript:  d[KEYS.transcript] || '',
      enSessions:  Array.isArray(d[KEYS.enSessions])  ? d[KEYS.enSessions]  : [],
      enRecurring: Array.isArray(d[KEYS.enRecurring]) ? d[KEYS.enRecurring] : [],
    };
  }

  function saveTranscript(text) {
    chrome.storage.local.set({ [KEYS.transcript]: text });
  }

  function saveEnglish(sessions, recurring) {
    return chrome.storage.local.set({
      [KEYS.enSessions]:  sessions,
      [KEYS.enRecurring]: recurring,
    });
  }

  async function exportEnglishJson() {
    const d = await load();
    return JSON.stringify({
      format:      EXPORT_FORMAT,
      exported_at: new Date().toISOString(),
      sessions:    d.enSessions,
      recurring:   d.enRecurring,
    }, null, 2);
  }

  // インポートは「混ぜる」方式。同じ id のセッションは二重に増やさず、
  // 繰り返し指摘は同じ文言なら回数の大きい方を残す（同じファイルを2回読んでも壊れない）
  function normKey(text) {
    return String(text || '').toLowerCase().replace(/\s+/g, ' ').trim();
  }

  function mergeSessions(current, incoming) {
    const seen = new Set(current.map(s => String(s.id)));
    const added = (incoming || []).filter(s => s && s.id && !seen.has(String(s.id)));
    // id は ISO 文字列 or タイムスタンプ。新しい順（降順）を保つ
    return [...current, ...added].sort((a, b) => String(b.id).localeCompare(String(a.id)));
  }

  function mergeRecurring(current, incoming) {
    const map = new Map(current.map(r => [normKey(r.text), { ...r }]));
    for (const r of (incoming || [])) {
      if (!r || !r.text) continue;
      const key = normKey(r.text);
      const cur = map.get(key);
      if (!cur) { map.set(key, { ...r }); continue; }
      cur.count = Math.max(cur.count || 0, r.count || 0);
      if (String(r.last_seen || '') > String(cur.last_seen || '')) cur.last_seen = r.last_seen;
    }
    return [...map.values()];
  }

  // 成功したら { sessions: 追加された件数, recurring: 取り込み後の件数 } を返す。
  // 読めない・形式違いは Error を投げる（呼び出し側が文言を出す）
  async function importEnglishJson(jsonText) {
    let data;
    try { data = JSON.parse(jsonText); } catch { throw new Error('not-json'); }
    if (!data || typeof data !== 'object' || !IMPORT_FORMATS.includes(data.format)) {
      throw new Error('bad-format');
    }

    const d = await load();
    const before = d.enSessions.length;
    const sessions  = mergeSessions(d.enSessions, data.sessions);
    const recurring = mergeRecurring(d.enRecurring, data.recurring);
    await saveEnglish(sessions, recurring);
    return { sessions: sessions.length - before, recurring: recurring.length };
  }

  return { KEYS, load, saveTranscript, saveEnglish, exportEnglishJson, importEnglishJson };
})();
