// ============================================================
// 表現集（覚えたい表現・単語）と「今日の表現」の純ロジック
// ============================================================
// 実行環境固有の API（chrome.*・DOM）には触れない。
// test/phrase_test.mjs がマーカーで囲んだ部分を切り出して Node で検証する。
//
// 考え方（30 日チャレンジで手運用していた「表現プール」をそのままアプリに持ち込む）:
//   - 毎日、覚えたい表現をいくつか提示する（数は設定で決める）
//   - 独り言の中で実際に使えたかを判定する
//       ◎ hit     … 形のまま使えた
//       △ partial … 使おうとしたが形が崩れた
//       ✗ miss    … 出なかった
//       − skip    … その日の話に合わなかった（見送り。責めないので回数に数えない）
//   - ◎ が 3 回で「卒業」。1 回目のあとは 1 週間後、2 回目のあとは 3 週間後に戻す
//     （単語帳アプリの「間隔を広げる」定石を、独り言で確かめられる粒度に絞ったもの）
//   - △ と ✗ は翌日にもう一度出す。見送りは 2 日あける
//   - 「カードで復習」（意味を見て言えるか自分で確かめる）は、言えなかったときだけ翌日に戻す。
//     言えただけでは卒業に近づかない。独り言の中で使えたことだけを定着の証拠にする

// ===== 表現集のロジック（ここから）=====

const PH_GRADUATE_HITS = 3;          // ◎ が何回で卒業か
const PH_LADDER_DAYS   = [7, 21];    // ◎ 1 回目のあと 7 日、2 回目のあと 21 日で戻す
const PH_MISS_DAYS     = 1;          // ✗ は翌日
const PH_PARTIAL_DAYS  = 1;          // △ は翌日
const PH_SKIP_DAYS     = 2;          // 見送りは 2 日あける
const PH_RECALL_NG_DAYS = 1;         // カードで言えなかったら翌日
const PH_DEFAULT_TOTAL = 5;          // 1 日に出す表現の数（設定で変えられる）
const PH_DEFAULT_NEW   = 3;          // そのうち、まだ一度も試していない表現の上限
const PH_MAX_PHRASES   = 2000;       // 保持上限（超えたら卒業済みの古いものから落とす）

const PH_KINDS   = ['phrase', 'word'];
const PH_RESULTS = ['hit', 'partial', 'miss', 'skip', 'rok', 'rng'];   // rok/rng はカード復習の言えた／言えなかった

// ---------- 日付（'YYYY-MM-DD' の文字列で扱う。時刻の影響を受けないように） ----------
function phDateStr(d) {
  const p = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function phAddDays(dateStr, n) {
  const [y, m, d] = String(dateStr).split('-').map(Number);
  const dt = new Date(y, m - 1, d + n);
  return phDateStr(dt);
}

function phDaysBetween(from, to) {
  const [y1, m1, d1] = String(from).split('-').map(Number);
  const [y2, m2, d2] = String(to).split('-').map(Number);
  const a = Date.UTC(y1, m1 - 1, d1);
  const b = Date.UTC(y2, m2 - 1, d2);
  return Math.round((b - a) / 86400000);
}

// ---------- 正規化・キー ----------
function phraseKey(text) {
  return String(text || '').toLowerCase().replace(/[’‘]/g, "'").replace(/\s+/g, ' ').trim();
}

function phNewId(today) {
  return `${today}-${Math.random().toString(36).slice(2, 8)}`;
}

// 1 件の表現カードを作る。meaning は日本語の意味（無くてもよい）
function makePhrase({ phrase, meaning = '', kind = 'phrase', source = 'manual', today, note = '' }) {
  const p = String(phrase || '').replace(/\s+/g, ' ').trim();
  if (!p) return null;
  return {
    id:      phNewId(today),
    phrase:  p,
    meaning: String(meaning || '').trim(),
    note:    String(note || '').trim(),
    kind:    PH_KINDS.includes(kind) ? kind : 'phrase',
    source:  source === 'issue' ? 'issue' : 'manual',
    added:   today,
    due:     today,
    hits:    0,
    status:  'active',
    history: [],   // [{ d: 'YYYY-MM-DD', r: 'hit'|'partial'|'miss'|'skip'|'rok'|'rng', as?: '口から出た形' }]
  };
}

// まとめて追加する欄の 1 行 → { phrase, meaning }
// 区切りは タブ・｜・|・—・–・「 - 」のどれか。区切りが無ければ全体を表現にする
function parsePhraseLine(line) {
  const s = String(line || '').trim();
  if (!s) return null;
  const m = s.match(/^(.+?)(?:\t+|\s*[｜|—–]\s*|\s+-\s+)(.+)$/);
  if (m) return { phrase: m[1].trim(), meaning: m[2].trim() };
  return { phrase: s, meaning: '' };
}

function parsePhraseLines(text) {
  return String(text || '').split(/\r?\n/).map(parsePhraseLine).filter(Boolean);
}

// 既にある表現（同じ文字列）は増やさない。返り値は { list, added }
function addPhrases(list, newOnes) {
  const cur  = Array.isArray(list) ? list.slice() : [];
  const seen = new Set(cur.map(p => phraseKey(p.phrase)));
  let added = 0;
  for (const p of (newOnes || [])) {
    if (!p || !p.phrase) continue;
    const key = phraseKey(p.phrase);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    cur.push(p);
    added++;
  }
  return { list: cur, added };
}

function findPhrase(list, text) {
  const key = phraseKey(text);
  return (Array.isArray(list) ? list : []).find(p => phraseKey(p.phrase) === key) || null;
}

// ---------- 履歴から状態（hits / due / status）を組み立て直す ----------
// 結果を後から直せるように、状態は履歴からいつでも再計算できる形にしておく
function rebuildPhrase(card) {
  const c = { ...card, history: (card.history || []).slice().sort((a, b) => String(a.d).localeCompare(String(b.d))) };
  let hits = 0;
  let due = c.added || c.history[0]?.d || '';
  let status = 'active';

  for (const h of c.history) {
    switch (h.r) {
      case 'hit':
        hits++;
        if (hits >= PH_GRADUATE_HITS) { status = 'graduated'; due = null; }
        else { due = phAddDays(h.d, PH_LADDER_DAYS[hits - 1] || PH_LADDER_DAYS[PH_LADDER_DAYS.length - 1]); }
        break;
      case 'partial': due = phAddDays(h.d, PH_PARTIAL_DAYS); break;
      case 'miss':    due = phAddDays(h.d, PH_MISS_DAYS);    break;
      case 'skip':    due = phAddDays(h.d, PH_SKIP_DAYS);    break;
      case 'rok':     break;   // 言えただけでは予定を動かさない
      case 'rng':
        // 卒業していても、言えなかったら稽古に戻す（あと 1 回の ◎ で再卒業）
        if (status === 'graduated') { status = 'active'; hits = PH_GRADUATE_HITS - 1; }
        due = phAddDays(h.d, PH_RECALL_NG_DAYS);
        break;
    }
  }
  // 手で「卒業」「稽古に戻す」を押した記録は履歴の外（manual）で持つ
  if (card.manual === 'graduated') { status = 'graduated'; due = null; }
  if (card.manual === 'active' && status === 'graduated') { status = 'active'; due = due || c.history[c.history.length - 1]?.d || c.added; }

  c.hits = hits;
  c.due = due;
  c.status = card.status === 'archived' ? 'archived' : status;
  return c;
}

// その日の結果を記録する（同じ日の独り言の結果は 1 つだけ。後から直したら置き換える）
function setSpeechResult(card, today, result, asSaid = '') {
  if (!PH_RESULTS.includes(result)) return card;
  const history = (card.history || []).filter(h => !(h.d === today && h.r !== 'rok' && h.r !== 'rng'));
  const entry = { d: today, r: result };
  if (asSaid) entry.as = String(asSaid).trim();
  history.push(entry);
  return rebuildPhrase({ ...card, history, manual: card.manual === 'graduated' ? '' : card.manual });
}

// カードで復習した結果（言えた／言えなかった）。同じ日に何度やっても最後のものだけ残す
function setRecallResult(card, today, ok) {
  const history = (card.history || []).filter(h => !(h.d === today && (h.r === 'rok' || h.r === 'rng')));
  history.push({ d: today, r: ok ? 'rok' : 'rng' });
  return rebuildPhrase({ ...card, history, manual: (!ok && card.manual === 'graduated') ? '' : card.manual });
}

function setManualStatus(card, status, today) {
  if (status === 'graduated') return rebuildPhrase({ ...card, manual: 'graduated' });
  if (status === 'active') {
    const c = rebuildPhrase({ ...card, manual: 'active' });
    if (!c.due) c.due = today;
    return c;
  }
  return card;
}

function phraseSpeechResults(card) {
  return (card.history || []).filter(h => h.r !== 'rok' && h.r !== 'rng');
}

function isNewPhrase(card) {
  return phraseSpeechResults(card).length === 0;
}

function lastSpeechResult(card) {
  const list = phraseSpeechResults(card);
  return list.length ? list[list.length - 1].r : '';
}

// ---------- 今日の表現を選ぶ ----------
// 優先順位（表現プールの運用と同じ）:
//   1. 前回 ✗ か △ だったもの（出せていないものを最優先で戻す）
//   2. 期日が来ているもの（遅れている順）
//   3. まだ一度も試していないもの（maxNew 件まで。新しく入れたものから）
// すでに今日の分が決まっていれば（fixedIds）、それを優先して保つ。日をまたいだら選び直す
function pickTodayPhrases(list, today, { total = PH_DEFAULT_TOTAL, maxNew = PH_DEFAULT_NEW, fixedIds = [] } = {}) {
  const all = (Array.isArray(list) ? list : []).filter(p => p && p.status === 'active');
  const byId = new Map(all.map(p => [p.id, p]));
  const picked = [];
  const used = new Set();

  for (const id of fixedIds) {
    const p = byId.get(id);
    if (p && !used.has(id)) { picked.push(p); used.add(id); }
  }
  const newCount = () => picked.filter(isNewPhrase).length;

  const due = all.filter(p => !used.has(p.id) && !isNewPhrase(p) && p.due && p.due <= today);
  const retry = due.filter(p => ['miss', 'partial'].includes(lastSpeechResult(p)));
  const rest  = due.filter(p => !retry.includes(p));
  const byDue = (a, b) => String(a.due).localeCompare(String(b.due)) || String(a.added).localeCompare(String(b.added));
  retry.sort(byDue);
  rest.sort(byDue);

  for (const p of [...retry, ...rest]) {
    if (picked.length >= total) break;
    picked.push(p); used.add(p.id);
  }

  const fresh = all.filter(p => !used.has(p.id) && isNewPhrase(p) && p.due && p.due <= today)
    .sort((a, b) => String(b.added).localeCompare(String(a.added)) || String(b.id).localeCompare(String(a.id)));
  for (const p of fresh) {
    if (picked.length >= total || newCount() >= maxNew) break;
    picked.push(p); used.add(p.id);
  }
  return picked;
}

// ---------- 独り言の中に表現が出たかを判定する ----------
// 音声認識の書き起こしは語尾や冠詞が揺れるので、語幹で比べ、少しの飛びを許す。
//   exact   … 全部の語が順に、間を空けずに出た（時制・単複の揺れは exact に含める）
//   partial … 語幹は出ているが、間に別の語が挟まった／冠詞などが落ちた
//   none    … 出ていない
// 「someone」「something」「〜」などは何か 1〜3 語が入る穴として扱う
const PH_WILDCARDS = new Set(['someone', 'somebody', 'something', 'sb', 'sth', "one's", "someone's", 'oneself', 'sth.', 'sb.']);
const PH_OPTIONAL  = new Set(['a', 'an', 'the', 'my', 'your', 'his', 'her', 'its', 'our', 'their', 'to', 'be']);

// 不規則変化は語幹に戻してから比べる（kept → keep、paid → pay、was → be）
const PH_IRREGULAR = {
  am: 'be', is: 'be', are: 'be', was: 'be', were: 'be', been: 'be', being: 'be',
  has: 'have', had: 'have', did: 'do', done: 'do', does: 'do',
  went: 'go', gone: 'go', goes: 'go', came: 'come', ran: 'run', took: 'take', taken: 'take',
  made: 'make', got: 'get', gotten: 'get', gave: 'give', given: 'give', saw: 'see', seen: 'see',
  knew: 'know', known: 'know', thought: 'think', felt: 'feel', kept: 'keep', told: 'tell',
  said: 'say', paid: 'pay', laid: 'lay', drew: 'draw', drawn: 'draw', spoke: 'speak', spoken: 'speak',
  wrote: 'write', written: 'write', broke: 'break', broken: 'break', brought: 'bring', bought: 'buy',
  caught: 'catch', taught: 'teach', found: 'find', held: 'hold', left: 'leave', lost: 'lose',
  met: 'meet', sat: 'sit', sold: 'sell', sent: 'send', stood: 'stand', understood: 'understand',
  woke: 'wake', wore: 'wear', worn: 'wear', won: 'win', fell: 'fall', fallen: 'fall', flew: 'fly',
  forgot: 'forget', forgotten: 'forget', grew: 'grow', grown: 'grow', hid: 'hide', hidden: 'hide',
  ate: 'eat', eaten: 'eat', began: 'begin', begun: 'begin', chose: 'choose', chosen: 'choose',
  led: 'lead', meant: 'mean', built: 'build', spent: 'spend', slept: 'sleep', threw: 'throw', thrown: 'throw',
  stuck: 'stick', struck: 'strike', shook: 'shake', rose: 'rise', risen: 'rise', sang: 'sing', swam: 'swim',
  became: 'become', forgave: 'forgive', froze: 'freeze', fed: 'feed', bit: 'bite', beat: 'beat', lent: 'lend',
  children: 'child', people: 'person', men: 'man', women: 'woman', feet: 'foot', teeth: 'tooth', mice: 'mouse',
};

function phStem(word) {
  let w = String(word || '').toLowerCase().replace(/[’‘]/g, "'").replace(/[^a-z']/g, '');
  if (!w) return '';
  if (PH_IRREGULAR[w]) return PH_IRREGULAR[w];
  for (const suf of ['ing', 'ed', 'es', 's']) {
    if (w.length - suf.length >= 3 && w.endsWith(suf)) { w = w.slice(0, -suf.length); break; }
  }
  if (w.length >= 4 && w[w.length - 1] === w[w.length - 2]) w = w.slice(0, -1);   // hogg → hog
  return w;
}

function phStemEq(a, b) {
  if (!a || !b) return false;
  if (a === b) return true;
  if (a + 'e' === b || b + 'e' === a) return true;   // hop / hope, wander / wandere
  if (a + 'i' === b || b + 'i' === a) return true;   // studi(es) / study
  return false;
}

// 表現を「照合用トークン列」にする。返り値は候補の配列（「／」で区切った別形ごと）
function phraseTokenAlternatives(phrase) {
  const cleaned = String(phrase || '').replace(/\([^)]*\)|（[^）]*）/g, ' ');   // (still) のような補足は外す
  return cleaned.split(/\s*[／/]\s*/).map(alt => {
    const raw = alt.replace(/[’‘]/g, "'").split(/\s+/).map(t => t.trim()).filter(Boolean);
    const toks = [];
    for (const t of raw) {
      const low = t.toLowerCase().replace(/^[^a-z〜~…]+|[^a-z'〜~…]+$/g, '');
      if (!low) continue;
      if (PH_WILDCARDS.has(low) || /[〜~…]/.test(low) || /^x+$/.test(low)) { toks.push({ wild: true }); continue; }
      toks.push({ stem: phStem(low), optional: PH_OPTIONAL.has(low) });
    }
    return toks;
  }).filter(t => t.some(x => !x.wild && !x.optional));
}

// 本文の語を語幹列にする。n't は not に開く（didn't even know → did not even know）
function textWords(text) {
  return String(text || '').replace(/[’‘]/g, "'").replace(/n't\b/gi, ' not').split(/[^A-Za-z']+/).filter(Boolean);
}

function textStems(text) {
  return textWords(text).map(phStem).filter(Boolean);
}

// 1 つの候補（トークン列）を本文の語幹列に当てる。見つかれば { exact, start, end }
function matchTokens(toks, stems) {
  let best = null;
  for (let start = 0; start < stems.length; start++) {
    let i = start, ti = 0, gaps = 0, dropped = 0;
    let ok = true;
    while (ti < toks.length) {
      const tk = toks[ti];
      if (tk.wild) {
        // 穴: 1〜3 語を飲み込む。次の実トークンが見つかる位置まで進める
        const next = toks.slice(ti + 1).find(x => !x.wild && !x.optional);
        let consumed = 0;
        if (!next) { i += 1; ti++; continue; }
        let found = -1;
        for (let k = i; k <= Math.min(stems.length - 1, i + 3); k++) {
          if (phStemEq(stems[k], next.stem)) { found = k; break; }
        }
        if (found < 0) { ok = false; break; }
        consumed = found - i;
        if (consumed === 0) { /* 穴に何も入らなかった（I almost ~ed の直後など）。許す */ }
        i = found; ti++;
        // 穴と次の実トークンの間の optional は飛ばす
        while (ti < toks.length && toks[ti].optional) ti++;
        continue;
      }
      if (i >= stems.length) { ok = false; break; }
      if (phStemEq(stems[i], tk.stem)) { i++; ti++; continue; }
      if (tk.optional) { dropped++; ti++; continue; }          // 冠詞などが落ちた
      // 間に 1 語だけ挟まるのを許す（"connected it's a dot" のような崩れ）
      if (i + 1 < stems.length && phStemEq(stems[i + 1], tk.stem) && gaps < 2) { gaps++; i += 2; ti++; continue; }
      if (i + 2 < stems.length && phStemEq(stems[i + 2], tk.stem) && gaps < 1) { gaps += 2; i += 3; ti++; continue; }
      ok = false; break;
    }
    if (!ok) continue;
    const exact = gaps === 0 && dropped === 0;
    const cand = { exact, start, end: i };
    if (!best || (cand.exact && !best.exact)) best = cand;
    if (best.exact) break;
  }
  return best;
}

// 返り値: { used: bool, exact: bool, asSaid: '本文から抜き出した形' }
function detectPhrase(phrase, text) {
  const words = textWords(text);
  const stems = words.map(phStem);
  let best = null;
  for (const toks of phraseTokenAlternatives(phrase)) {
    const m = matchTokens(toks, stems);
    if (m && (!best || (m.exact && !best.exact))) best = m;
    if (best && best.exact) break;
  }
  if (!best) return { used: false, exact: false, asSaid: '' };
  return { used: true, exact: best.exact, asSaid: words.slice(best.start, best.end).join(' ') };
}

// 今日の表現それぞれを本文に当てて、◎△✗ を出す
function judgePhrases(cards, text) {
  return (cards || []).map(c => {
    const d = detectPhrase(c.phrase, text);
    return { id: c.id, result: !d.used ? 'miss' : (d.exact ? 'hit' : 'partial'), asSaid: d.asSaid, judge: 'auto' };
  });
}

// AI（Gemini）が返した targets を優先して重ねる。AI は音声を聞いているので、
// 文字の照合より「言おうとしたかどうか」の判断が正しい
function mergeAiTargets(judged, cards, aiTargets) {
  if (!Array.isArray(aiTargets) || aiTargets.length === 0) return judged;
  const byKey = new Map((cards || []).map(c => [phraseKey(c.phrase), c.id]));
  const out = judged.map(j => ({ ...j }));
  for (const t of aiTargets) {
    const id = byKey.get(phraseKey(t.phrase));
    if (!id) continue;
    const j = out.find(x => x.id === id);
    if (!j) continue;
    j.result = !t.used ? 'miss' : (t.exact ? 'hit' : 'partial');
    j.asSaid = t.used ? (t.as_said || j.asSaid) : '';
    j.note   = t.note || '';
    j.judge  = 'ai';
  }
  return out;
}

// AI へ渡す「今日の狙いの表現」の節（無ければ空文字。呼び出し側で末尾に足す）
function buildTargetsSection(cards) {
  const list = (cards || []).filter(c => c && c.phrase);
  if (list.length === 0) return '';
  const lines = list.map(c => `- ${c.phrase}${c.meaning ? `（${c.meaning}）` : ''}`);
  return `\n\n## 今日使うと決めていた表現（それぞれ使えたかを "targets" で判定してください）\n${lines.join('\n')}`;
}

// 表現集の件数（画面の見出し用）
function phraseStats(list) {
  const all = Array.isArray(list) ? list : [];
  return {
    total:     all.length,
    active:    all.filter(p => p.status === 'active' && !isNewPhrase(p)).length,
    fresh:     all.filter(p => p.status === 'active' && isNewPhrase(p)).length,
    graduated: all.filter(p => p.status === 'graduated').length,
  };
}

// 保持上限を超えたら、卒業済みの古いものから落とす
function trimPhrases(list, max = PH_MAX_PHRASES) {
  const all = Array.isArray(list) ? list.slice() : [];
  if (all.length <= max) return all;
  const grads = all.filter(p => p.status === 'graduated').sort((a, b) => String(a.added).localeCompare(String(b.added)));
  const drop = new Set(grads.slice(0, all.length - max).map(p => p.id));
  return all.filter(p => !drop.has(p.id)).slice(0, max);
}

// 履歴の記号列（◎△✗−／カードは ○×）。画面と Obsidian の表記を合わせる
function phraseMarks(card) {
  const M = { hit: '◎', partial: '△', miss: '✗', skip: '−', rok: '○', rng: '×' };
  return (card.history || []).map(h => M[h.r] || '').join('');
}
// ===== 表現集のロジック（ここまで）=====
