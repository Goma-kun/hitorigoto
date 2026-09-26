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
    enPhrases:   'en_phrases',      // 表現集（覚えたい表現・単語）
    enToday:     'en_today',        // 今日の表現（{ date, ids, results }）。日をまたいだら選び直す
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
      enPhrases:   Array.isArray(d[KEYS.enPhrases])   ? d[KEYS.enPhrases]   : [],
      enToday:     (d[KEYS.enToday] && typeof d[KEYS.enToday] === 'object') ? d[KEYS.enToday] : null,
    };
  }

  function savePhrases(phrases, today) {
    const obj = { [KEYS.enPhrases]: phrases };
    if (today !== undefined) obj[KEYS.enToday] = today;
    return chrome.storage.local.set(obj);
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
      phrases:     d.enPhrases,
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

  // 表現集は同じ表現なら履歴の長い方を残す（同じファイルを 2 回読んでも増えない）
  function mergePhrases(current, incoming) {
    const map = new Map(current.map(p => [normKey(p.phrase), p]));
    for (const p of (incoming || [])) {
      if (!p || !p.phrase) continue;
      const key = normKey(p.phrase);
      const cur = map.get(key);
      if (!cur || (p.history || []).length > (cur.history || []).length) map.set(key, { ...p });
    }
    return [...map.values()];
  }

  // 成功したら { sessions: 追加された件数, recurring: 取り込み後の件数, phrases: 取り込み後の件数 } を返す。
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
    const phrases   = mergePhrases(d.enPhrases, data.phrases);
    await saveEnglish(sessions, recurring);
    await chrome.storage.local.set({ [KEYS.enPhrases]: phrases });
    return { sessions: sessions.length - before, recurring: recurring.length, phrases: phrases.length };
  }

  return { KEYS, load, saveTranscript, saveEnglish, savePhrases, exportEnglishJson, importEnglishJson };
})();
