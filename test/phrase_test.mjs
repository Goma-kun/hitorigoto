// 表現集（phrase-core.js）のロジックを切り出して検証する。
//   実行: node test/phrase_test.mjs
// 照合の例は 30 日チャレンジの表現プール（実際に出た崩れ方）から取っている
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const START = '// ===== 表現集のロジック（ここから）=====';
const END   = '// ===== 表現集のロジック（ここまで）=====';
const src = fs.readFileSync(path.join(ROOT, 'extension/phrase-core.js'), 'utf8');
const s = src.indexOf(START), e = src.indexOf(END);
if (s < 0 || e < 0) throw new Error('マーカーが見つかりません');

const mod = new Function(`${src.slice(s, e)}
  return { phAddDays, phDaysBetween, phraseKey, makePhrase, parsePhraseLine, parsePhraseLines, addPhrases,
           rebuildPhrase, setSpeechResult, setRecallResult, setManualStatus, pickTodayPhrases,
           detectPhrase, judgePhrases, mergeAiTargets, buildTargetsSection, phraseStats, trimPhrases, phraseMarks,
           PH_DEFAULT_TOTAL, PH_DEFAULT_NEW };`)();
const {
  phAddDays, phDaysBetween, makePhrase, parsePhraseLine, parsePhraseLines, addPhrases,
  setSpeechResult, setRecallResult, setManualStatus, pickTodayPhrases,
  detectPhrase, judgePhrases, mergeAiTargets, buildTargetsSection, phraseStats, trimPhrases, phraseMarks,
} = mod;

let pass = 0, fail = 0;
function check(name, actual, expected) {
  const a = JSON.stringify(actual), x = JSON.stringify(expected);
  if (a === x) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name}\n       期待: ${x}\n       実際: ${a}`); }
}

const D = '2026-09-27';
const mk = (phrase, meaning = '', extra = {}) => ({ ...makePhrase({ phrase, meaning, today: D }), ...extra });

console.log('== 日付 ==');
check('7 日後',         phAddDays('2026-09-27', 7), '2026-10-04');
check('月またぎ',       phAddDays('2026-09-30', 1), '2026-10-01');
check('年またぎ',       phAddDays('2026-12-31', 1), '2027-01-01');
check('日数の差',       phDaysBetween('2026-09-27', '2026-10-04'), 7);

console.log('== まとめて追加の 1 行 ==');
check('｜ 区切り',      parsePhraseLine('under the hood ｜ 裏側の仕組み'), { phrase: 'under the hood', meaning: '裏側の仕組み' });
check('— 区切り',       parsePhraseLine('in-house — 自社内で'), { phrase: 'in-house', meaning: '自社内で' });
check('タブ区切り',     parsePhraseLine('draw a blank\t何も浮かばない'), { phrase: 'draw a blank', meaning: '何も浮かばない' });
check('" - " 区切り',   parsePhraseLine('come clean - 白状する'), { phrase: 'come clean', meaning: '白状する' });
check('ハイフン語は割らない', parsePhraseLine('a husband-and-wife team'), { phrase: 'a husband-and-wife team', meaning: '' });
check('区切り無し',     parsePhraseLine('second nature'), { phrase: 'second nature', meaning: '' });
check('空行は捨てる',   parsePhraseLines('a ｜ x\n\n  \nb ｜ y').length, 2);

console.log('== 追加と重複 ==');
{
  const r1 = addPhrases([], [mk('It hit me', 'はっと気づいた'), mk('it hit me'), null]);
  check('同じ表現は 1 件',        r1.list.length, 1);
  check('追加件数',               r1.added, 1);
  const r2 = addPhrases(r1.list, [mk('IT  HIT ME')]);
  check('大文字・空白違いも同じ', r2.added, 0);
  check('新規カードは status active・due 今日', [r1.list[0].status, r1.list[0].due, r1.list[0].hits], ['active', D, 0]);
}

console.log('== 独り言の結果と次の予定 ==');
{
  let c = mk('for a split second', 'ほんの一瞬');
  c = setSpeechResult(c, '2026-09-14', 'miss');
  check('✗ → 翌日',              c.due, '2026-09-15');
  c = setSpeechResult(c, '2026-09-21', 'hit');
  check('◎ 1 回目 → 7 日後',      [c.hits, c.due], [1, '2026-09-28']);
  c = setSpeechResult(c, '2026-09-28', 'partial');
  check('△ → 翌日（◎ は増えない）', [c.hits, c.due], [1, '2026-09-29']);
  c = setSpeechResult(c, '2026-09-29', 'hit');
  check('◎ 2 回目 → 21 日後',     [c.hits, c.due], [2, '2026-10-20']);
  c = setSpeechResult(c, '2026-10-20', 'skip');
  check('見送り → 2 日あける・回数そのまま', [c.hits, c.due], [2, '2026-10-22']);
  c = setSpeechResult(c, '2026-10-22', 'hit');
  check('◎ 3 回目で卒業',         [c.hits, c.status, c.due], [3, 'graduated', null]);
  check('記号列',                 phraseMarks(c), '✗◎△◎−◎');
  // 同じ日の結果を後から直す
  let d = setSpeechResult(mk('x'), D, 'miss');
  d = setSpeechResult(d, D, 'hit');
  check('同じ日の結果は置き換え', [d.history.length, d.hits, d.due], [1, 1, phAddDays(D, 7)]);
  // 卒業した表現をカードで言えなかったら稽古に戻す
  let g = setSpeechResult(setSpeechResult(setSpeechResult(mk('y'), '2026-09-01', 'hit'), '2026-09-08', 'hit'), '2026-09-29', 'hit');
  check('卒業している',           g.status, 'graduated');
  g = setRecallResult(g, '2026-10-05', false);
  check('言えなかった → 稽古に戻る・翌日', [g.status, g.hits, g.due], ['active', 2, '2026-10-06']);
  g = setRecallResult(g, '2026-10-06', true);
  check('言えただけでは予定は動かない', g.due, '2026-10-06');
  // 手動の卒業と復帰
  let m = setManualStatus(mk('z'), 'graduated', D);
  check('手動で卒業',             [m.status, m.due], ['graduated', null]);
  m = setManualStatus(m, 'active', D);
  check('稽古に戻す',             [m.status, m.due], ['active', D]);
}

console.log('== 今日の表現を選ぶ ==');
{
  const list = [
    mk('new-1', '', { id: 'n1', added: '2026-09-25' }),
    mk('new-2', '', { id: 'n2', added: '2026-09-26' }),
    mk('new-3', '', { id: 'n3', added: '2026-09-27' }),
    mk('new-4', '', { id: 'n4', added: '2026-09-27' }),
    setSpeechResult(mk('missed', '', { id: 'm1' }), '2026-09-26', 'miss'),          // due 9/27
    setSpeechResult(mk('hit-old', '', { id: 'h1' }), '2026-09-10', 'hit'),          // due 9/17（遅れ）
    setSpeechResult(mk('hit-recent', '', { id: 'h2' }), '2026-09-26', 'hit'),       // due 10/3（まだ）
    setSpeechResult(mk('grad', '', { id: 'g1' }), '2026-09-01', 'hit'),
  ];
  list[7] = setSpeechResult(setSpeechResult(list[7], '2026-09-08', 'hit'), '2026-09-29', 'hit');
  const picked = pickTodayPhrases(list, D, { total: 5, maxNew: 2 });
  check('✗ が先頭、次に遅れている ◎、新規は上限まで', picked.map(p => p.id), ['m1', 'h1', 'n4', 'n3']);
  check('新規の上限が効く（4 件で止まる）', picked.length, 4);
  const fixed = pickTodayPhrases(list, D, { total: 5, maxNew: 2, fixedIds: ['n1', 'h1'] });
  check('決めてある分は保つ',      fixed.map(p => p.id).slice(0, 2), ['n1', 'h1']);
  check('決めてある分も新規の上限に数える', fixed.filter(p => p.id.startsWith('n')).length, 2);
  const none = pickTodayPhrases([], D);
  check('空なら空',               none, []);
}

console.log('== 独り言の中に出たか（表現プールの実例）==');
const T = (phrase, text) => { const d = detectPhrase(phrase, text); return d.used ? (d.exact ? 'hit' : 'partial') : 'miss'; };
check('形のまま',               T('for a split second', 'For a split second, he looked straight into the lens.'), 'hit');
check('進行形（hog → hogging）', T('hog someone\'s food', 'it turned out that the kitten was hogging his food'), 'hit');
check('過去形（turn out）',      T('it turned out', 'It turned out that the kitten was hogging his food.'), 'hit');
check('受け身の進行形',          T('he was being filmed', "he didn't even notice he was being filmed"), 'hit');
check('単数で出た（moments → moment）', T('capture candid moments', 'I could capture a candid moment'), 'partial');
check('崩れて出た（connect the dots）', T('connect the dots', "and then it connected it's a dot"), 'partial');
check('進行形で出た（paid → paying）', T('I should have paid closer attention', 'I should have been paying closer attention to him'), 'partial');
check('出なかった',              T('rule out anything serious', 'I took him to the vet and they ran a test.'), 'miss');
check('別の語に化けた（on the mat）', T("he's on the mend", 'Then, he is on the mat now'), 'miss');
check('／ の別形（keep a record of）', T('keep track of ／ keep a record of', 'I kept a record of how much he ate'), 'hit');
check('穴つき（I almost 〜ed）',  T('I almost 〜ed', 'I almost missed the train'), 'hit');
check('sub が落ちた（△）',       T('subcutaneous fluids', 'the vet gave him cutaneous fluids'), 'miss');
check('大文字と句読点',          T('not even know the name', "I didn't even know the doctor's name!"), 'partial');
check('the が落ちた',            T('look straight into the lens', 'he looked straight into lens'), 'partial');
check('短い語で誤爆しない',      T('the', 'then there is a theory'), 'miss');
check('単語 1 つ',               T('tweak', 'I tweaked the script a little'), 'hit');
check('空の本文',                T('tweak', ''), 'miss');
{
  const d = detectPhrase('hog someone\'s food', 'the kitten was hogging his food at night');
  check('口から出た形を抜き出す', d.asSaid, 'hogging his food');
}

console.log('== AI の判定を重ねる ==');
{
  const cards = [mk('on the mend', '', { id: 'a' }), mk('draw a blank', '', { id: 'b' }), mk('tweak', '', { id: 'c' })];
  const text = 'he is on the mat now. I do a completely blank.';
  const auto = judgePhrases(cards, text);
  check('文字の照合だけだと ✗✗✗', auto.map(j => j.result), ['miss', 'miss', 'miss']);
  const merged = mergeAiTargets(auto, cards, [
    { phrase: 'On the mend', used: true, exact: true, as_said: 'on the mend', note: '' },
    { phrase: 'draw a blank', used: true, exact: false, as_said: 'do a completely blank', note: 'draw だ、do じゃねえ' },
    { phrase: '知らない表現', used: true, exact: true },
  ]);
  check('AI が聞き取った ◎ を優先', [merged[0].result, merged[0].asSaid, merged[0].judge], ['hit', 'on the mend', 'ai']);
  check('崩れは △',               [merged[1].result, merged[1].note], ['partial', 'draw だ、do じゃねえ']);
  check('AI が触れなかったものは自動判定のまま', merged[2].judge, 'auto');
  check('AI 無しならそのまま',     mergeAiTargets(auto, cards, []), auto);
}

console.log('== AI へ渡す節 ==');
check('無ければ空',    buildTargetsSection([]), '');
check('表現と意味',    buildTargetsSection([mk('under the hood', '裏側の仕組み'), mk('in-house')]).includes('- under the hood（裏側の仕組み）\n- in-house'), true);

console.log('== 件数と上限 ==');
{
  const list = [mk('a'), setSpeechResult(mk('b'), D, 'miss'), setManualStatus(mk('c'), 'graduated', D)];
  check('件数', phraseStats(list), { total: 3, active: 1, fresh: 1, graduated: 1 });
  const big = Array.from({ length: 6 }, (_, i) => setManualStatus(mk('g' + i, '', { added: `2026-01-0${i + 1}` }), 'graduated', D));
  big.push(mk('keep'));
  const trimmed = trimPhrases(big, 4);
  check('卒業済みの古いものから落とす', trimmed.map(p => p.phrase), ['g3', 'g4', 'g5', 'keep']);
}

console.log('');
console.log(`結果: ${pass} 件成功 / ${fail} 件失敗`);
process.exit(fail === 0 ? 0 : 1);
