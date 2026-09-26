// 「今日の狙いの表現」の判定（targets）を、本物の Gemini（テキストモード）で確かめる。
//   実行: node test/targets_e2e.mjs
// - Gemini API キーは ~/.config/nishira/gemini_api_key から読む（表示しない・リポジトリに入れない）
// - 本番と同じ経路（ai-providers.js の createGeminiProvider → reviewEnglish）を通す
import fs from 'node:fs';
import path from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const KEY  = fs.readFileSync(`${homedir()}/.config/nishira/gemini_api_key`, 'utf8').trim();
const read = f => fs.readFileSync(path.join(ROOT, 'extension', f), 'utf8');
const cut  = (src, a, b) => src.slice(src.indexOf(a), src.indexOf(b));

const core   = cut(read('english-core.js'), '// ===== 英語学習モードのロジック（ここから）=====', '// ===== 英語学習モードのロジック（ここまで）=====');
const phrase = cut(read('phrase-core.js'),  '// ===== 表現集のロジック（ここから）=====',      '// ===== 表現集のロジック（ここまで）=====');
const mod = new Function(`${core}\n${phrase}\n${read('ai-providers.js')}
  return { createGeminiProvider, makePhrase, buildTargetsSection, judgePhrases, mergeAiTargets };`)();

const today = '2026-09-27';
const cards = [
  mod.makePhrase({ phrase: "he's on the mend", meaning: '回復に向かっている', today }),
  mod.makePhrase({ phrase: 'draw a blank', meaning: '何も浮かばない', today }),
  mod.makePhrase({ phrase: 'rule out anything serious', meaning: '重い病気を除外する', today }),
  mod.makePhrase({ phrase: 'for a split second', meaning: 'ほんの一瞬', today }),
];
// Day 17・15 の実例に近い崩れ方: on the mat（認識ミス）、do a completely blank（崩れ）、for a split second（形のまま）、rule out は出ない
const text = `Yesterday I took my cat to the vet again. He is eating more than last week, so I think he is on the mat now.
When the doctor asked me about his weight, I do a completely blank. I could not remember the number.
For a split second, I thought about going home. But I stayed and they ran a test.`;

const ai = mod.createGeminiProvider(KEY);
const t0 = Date.now();
const fb = await ai.reviewEnglish(text, [], mod.buildTargetsSection(cards));
console.log(`応答 ${((Date.now() - t0) / 1000).toFixed(1)} 秒`);
console.log('targets:', JSON.stringify(fb.targets, null, 2));
console.log('good:', fb.good);
console.log('issues:', fb.issues.map(i => `${i.original} → ${i.suggestion}`).join(' / '));
const merged = mod.mergeAiTargets(mod.judgePhrases(cards, text), cards, fb.targets);
console.log('判定:', merged.map(m => `${cards.find(c => c.id === m.id).phrase} = ${m.result} (${m.judge})`).join(' / '));
let ok = true;
if (fb.targets.length !== 4) { console.log('NG: targets が 4 件でない'); ok = false; }
for (const t of fb.targets) if (!cards.some(c => c.phrase.toLowerCase() === t.phrase.toLowerCase())) { console.log('NG: 渡していない表現が入っている:', t.phrase); ok = false; }
const r = Object.fromEntries(merged.map(m => [cards.find(c => c.id === m.id).phrase, m.result]));
if (r['for a split second'] !== 'hit') { console.log('NG: for a split second が hit でない'); ok = false; }
if (r['rule out anything serious'] !== 'miss') { console.log('NG: rule out が miss でない'); ok = false; }
console.log(ok ? 'OK' : 'NG');
process.exit(ok ? 0 : 1);
