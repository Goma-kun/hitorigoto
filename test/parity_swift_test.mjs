// 拡張機能の english-core.js / phrase-core.js と、iOS/Mac 用に移した ios/Sources/HitorigotoCore が
// **同じ入力に同じ答えを返すか**を実際に突き合わせる。場面は機械的に大量生成する。
//
// 実行: node test/parity_swift_test.mjs（プロジェクトルートから）
//       事前に swift build --package-path ios が要る
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const cut = (file, a, b) => { const s = readFileSync(join(root, 'extension', file), 'utf8'); const i = s.indexOf(a), j = s.indexOf(b); if (i < 0 || j < 0) throw new Error(file); return s.slice(i, j); };
const core = cut('english-core.js', '// ===== 英語学習モードのロジック（ここから）=====', '// ===== 英語学習モードのロジック（ここまで）=====');
const phrase = cut('phrase-core.js', '// ===== 表現集のロジック（ここから）=====', '// ===== 表現集のロジック（ここまで）=====');
const ai = readFileSync(join(root, 'extension/ai-providers.js'), 'utf8');
const JS = new Function('parseFeedback0', 'buildEnglishUserMessage0', 'buildEnglishAudioUserMessage0', `${core}\n${phrase}\n${ai}
  return { parseFeedback, promoteRecurring, topRecurring, foldSessions, buildEnglishUserMessage, buildEnglishAudioUserMessage, buildSessionText,
           phAddDays, phDaysBetween, parsePhraseLine, detectPhrase, rebuildPhrase, setSpeechResult, setRecallResult, setManualStatus,
           pickTodayPhrases, judgePhrases, mergeAiTargets, buildTargetsSection, phraseStats, phraseMarks,
           EN_SYSTEM_PROMPT, EN_SYSTEM_PROMPT_AUDIO };`)();

let seed = 20260927;
const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const pick = a => a[Math.floor(rnd() * a.length)];
const ri = n => Math.floor(rnd() * n);

// 表現プールの実例＋つくった例
const PHRASES = ['under the hood', 'in-house', 'not even know the name', 'keep track of ／ keep a record of', 'connect the dots',
  'I should have paid closer attention', 'draw a blank', 'he knows how my mind works', 'rule out anything serious', 'where we go from here',
  "he's on the mend", 'hog someone\'s food', 'have him weighed', 'for a split second', 'look straight into the lens', 'he was being filmed',
  'capture candid moments', 'worth every yen', 'soak up', 'armor against illness', 'his appetite is (still) off', 'I almost 〜ed',
  'ask for someone by name', 'tweak', 'it hit me', 'the', 'a', 'bounce ideas off someone', 'take advantage of', 'subcutaneous fluids'];
const TEXTS = ['it turned out that the kitten was hogging his food at night', 'For a split second, he looked straight into the lens.',
  "he didn't even notice he was being filmed", 'I could capture a candid moment', "and then it connected it's a dot",
  'I should have been paying closer attention to him', 'I took him to the vet and they ran a test.', 'Then, he is on the mat now',
  'I kept a record of how much he ate', 'I almost missed the train', 'the vet gave him cutaneous fluids', "I didn't even know the doctor's name!",
  'he looked straight into lens', 'then there is a theory', 'I tweaked the script a little', '', 'Under the hood there is an AI. I do a completely blank.',
  'his appetite is off, still off, I think. It’s worth every yen. I asked for the doctor by name.', 'They ran tests to rule out anything serious and we talked about where we go from here'];
const DATES = ['2026-09-01', '2026-09-10', '2026-09-20', '2026-09-26', '2026-09-27', '2026-10-01', '2026-12-31'];
const RESULTS = ['hit', 'partial', 'miss', 'skip'];

function makeCard(i) {
  const added = pick(DATES);
  const card = { id: 'c' + i, phrase: pick(PHRASES), meaning: pick(['', '意味']), note: '', kind: pick(['phrase', 'word']), source: 'manual',
    added, due: added, hits: 0, status: 'active', history: [] };
  let c = card;
  const n = ri(5);
  let d = added;
  for (let k = 0; k < n; k++) {
    d = JS.phAddDays(d, 1 + ri(8));
    if (rnd() < 0.2) c = JS.setRecallResult(c, d, rnd() < 0.5);
    else c = JS.setSpeechResult(c, d, pick(RESULTS), rnd() < 0.3 ? 'as said' : '');
  }
  if (rnd() < 0.1) c = JS.setManualStatus(c, pick(['graduated', 'active']), d);
  return c;
}

const cases = [];
const expect = [];
const push = (c, e) => { cases.push(c); expect.push(e); };

// プロンプト
push({ fn: 'prompts' }, { system: JS.EN_SYSTEM_PROMPT, audio: JS.EN_SYSTEM_PROMPT_AUDIO });

// 応答の解釈
const SAMPLE = { corrected_text: 'I went.', issues: [{ type: 'VOCABULARY', original: 'a', suggestion: 'b', reason: 'r' }, { type: 'x', original: 'c', suggestion: 'd' }, { type: 'grammar', original: 'e' }],
  recurring: ['x', 3, ''], recognition_doubt: ['their'], good: 'g', transcript: 't', pronunciation: [{ said: 's', heard_as: 'h' }, { said: 'only' }],
  targets: [{ phrase: 'p', used: 1, exact: 'yes', as_said: 'x' }, { used: true }, { phrase: 'q', used: false }] };
for (const raw of [JSON.stringify(SAMPLE), '```json\n' + JSON.stringify(SAMPLE) + '\n```', 'はい。' + JSON.stringify({ ...SAMPLE, good: '括弧 } と "引用符"' }) + ' です',
  '{ "corrected_text": ', 'ローマ帝国は…', '{"corrected_text":"Hello."}', JSON.stringify({ issues: [] })]) {
  push({ fn: 'parseFeedback', raw }, JS.parseFeedback(raw));
}

// 繰り返し・畳み・メッセージ
{
  let prev = [];
  for (let i = 0; i < 6; i++) {
    const issues = Array.from({ length: ri(4) }, () => ({ type: 'grammar', original: pick(['a', 'b', 'c ', 'C']), suggestion: pick(['x', 'y']), reason: '' }));
    const today = pick(DATES);
    push({ fn: 'promoteRecurring', prev, issues, today }, JS.promoteRecurring(prev, issues, today));
    prev = JS.promoteRecurring(prev, issues, today);
  }
  push({ fn: 'topRecurring', list: prev }, JS.topRecurring(prev));
  push({ fn: 'topRecurring', list: prev, limit: 2, min: 1 }, JS.topRecurring(prev, 2, 1));
  const sessions = Array.from({ length: 40 }, (_, i) => ({ id: `2026-09-${String(30 - (i % 30)).padStart(2, '0')}T00:00:00.000Z-${i}`, transcript: 't', corrected_text: 'c',
    issues: [{ type: 'grammar', original: 'o', suggestion: 's', reason: 'r' }], good: 'g' }));
  push({ fn: 'foldSessions', sessions, keepFull: 3, keepTotal: 35 }, JS.foldSessions(sessions, 3, 35));
  const rec = JS.topRecurring(prev, 5, 1);
  push({ fn: 'userMessage', text: '  Hi there.\n', recurring: rec, extra: '' }, JS.buildEnglishUserMessage('  Hi there.\n', rec, ''));
  push({ fn: 'userMessage', text: '', recurring: [], extra: '\n\n## x', audio: true }, JS.buildEnglishAudioUserMessage('', [], '\n\n## x'));
  push({ fn: 'userMessage', text: 'asr', recurring: rec, extra: '', audio: true }, JS.buildEnglishAudioUserMessage('asr', rec, ''));
  const labels = { corrected: '修正版', issues: '指摘', good: 'よかった点', said: '話した内容', pron: '発音', types: { phrasing: '言い回し', vocabulary: '語彙', grammar: '文法' } };
  const s1 = { id: 'x', transcript: ' I go. ', corrected_text: 'I went.', issues: [{ type: 'grammar', original: 'go', suggestion: 'went', reason: 'r' }, { type: 'zzz', suggestion: 'only' }], good: 'g', pronunciation: [{ said: 'a', heard_as: 'b', note: '' }, { said: 'c', heard_as: 'd', note: 'n' }] };
  push({ fn: 'sessionText', session: s1, labels }, JS.buildSessionText(s1, labels));
  push({ fn: 'sessionText', session: { id: 'y', folded: true, issues: [{ type: 'grammar', suggestion: 's' }] }, labels }, JS.buildSessionText({ id: 'y', folded: true, issues: [{ type: 'grammar', suggestion: 's' }] }, labels));
}

// 日付
for (const d of DATES) for (const n of [-40, -1, 0, 1, 7, 21, 100]) push({ fn: 'addDays', date: d, n }, JS.phAddDays(d, n));
for (const a of DATES) for (const b of DATES) push({ fn: 'daysBetween', from: a, to: b }, JS.phDaysBetween(a, b));

// まとめて追加の 1 行
for (const line of ['a ｜ b', 'a | b', 'a — b', 'a – b', 'a\tb', 'a - b', 'a-b', 'a', '', '  x  ', 'a ｜ b ｜ c', 'in-house — 自社内で'])
  push({ fn: 'parsePhraseLine', line }, JS.parsePhraseLine(line));

// 照合（総当たり）
for (const p of PHRASES) for (const t of TEXTS) push({ fn: 'detect', phrase: p, text: t }, JS.detectPhrase(p, t));

// 履歴と状態
const cards = Array.from({ length: 60 }, (_, i) => makeCard(i));
for (const c of cards) {
  push({ fn: 'rebuild', card: c }, JS.rebuildPhrase(c));
  const today = pick(DATES), r = pick(RESULTS);
  push({ fn: 'setSpeechResult', card: c, today, result: r, asSaid: 'x' }, JS.setSpeechResult(c, today, r, 'x'));
  const ok = rnd() < 0.5, status = pick(['graduated', 'active']);
  push({ fn: 'setRecallResult', card: c, today, ok }, JS.setRecallResult(c, today, ok));
  push({ fn: 'setManualStatus', card: c, status, today }, JS.setManualStatus(c, status, today));
  push({ fn: 'marks', card: c }, JS.phraseMarks(c));
}
push({ fn: 'stats', list: cards }, JS.phraseStats(cards));
for (let i = 0; i < 30; i++) {
  const list = cards.slice(ri(10), 10 + ri(50));
  const today = pick(DATES), total = 1 + ri(8), maxNew = ri(5);
  const fixedIds = rnd() < 0.5 ? list.slice(0, ri(4)).map(c => c.id) : [];
  push({ fn: 'pickToday', list, today, total, maxNew, fixedIds }, JS.pickTodayPhrases(list, today, { total, maxNew, fixedIds }).map(c => c.id));
}
// AI 判定の重ね合わせ
{
  const cs = cards.slice(0, 5);
  const text = TEXTS[16];
  const aiT = [{ phrase: cs[0].phrase.toUpperCase(), used: true, exact: false, as_said: 'blah', note: 'n' }, { phrase: cs[1].phrase, used: false, exact: false, as_said: '', note: '' }, { phrase: '無関係', used: true, exact: true, as_said: '', note: '' }];
  push({ fn: 'mergeAiTargets', cards: cs, text, ai: aiT }, JS.mergeAiTargets(JS.judgePhrases(cs, text), cs, aiT));
  push({ fn: 'mergeAiTargets', cards: cs, text, ai: [] }, JS.judgePhrases(cs, text));
  push({ fn: 'targetsSection', cards: cs }, JS.buildTargetsSection(cs));
  push({ fn: 'targetsSection', cards: [] }, '');
}

// ---- Swift へ流す ----
const bin = join(root, 'ios/.build/debug/hg-probe');
const out = JSON.parse(execFileSync(bin, { input: JSON.stringify({ cases }), maxBuffer: 64 * 1024 * 1024 }).toString());
const results = out.results;

// JS 側の undefined は JSON では消える。Swift の nil も消える。キーの順は無視して比べる
const canon = v => JSON.stringify(v, (k, val) => (val && typeof val === 'object' && !Array.isArray(val))
  ? Object.fromEntries(Object.keys(val).sort().filter(k => val[k] !== undefined && val[k] !== null).map(k => [k, val[k]])) : val);

let pass = 0, fail = 0;
const failsByFn = {};
cases.forEach((c, i) => {
  const a = canon(results[i]), e = canon(JSON.parse(JSON.stringify(expect[i] ?? null)));
  if (a === e) { pass++; return; }
  fail++;
  failsByFn[c.fn] = (failsByFn[c.fn] || 0) + 1;
  if ((failsByFn[c.fn] || 0) <= 3) {
    console.log(`  FAIL ${c.fn} #${i}\n       入力: ${JSON.stringify(c).slice(0, 300)}\n       期待: ${e.slice(0, 400)}\n       実際: ${a.slice(0, 400)}`);
  }
});
console.log(`\n結果: ${pass} 件一致 / ${fail} 件不一致`, fail ? failsByFn : '');
process.exit(fail === 0 ? 0 : 1);
