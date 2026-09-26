// ai-providers.js のプロンプト組み立てを検証する。
// 音声モードの文面はテキスト用 EN_SYSTEM_PROMPT から目印を頼りに派生させているので、
// テキスト用を書き換えたときに目印が消えていないか、ここで気づけるようにしておく。
//   実行: node test/prompt_test.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const src  = fs.readFileSync(path.join(ROOT, 'extension/ai-providers.js'), 'utf8');

// english-core.js の関数はここでは呼ばれないので、名前だけ置く
const mod = new Function('parseFeedback', 'buildEnglishUserMessage', 'buildEnglishAudioUserMessage',
  `${src}
   return { EN_SYSTEM_PROMPT, EN_SYSTEM_PROMPT_AUDIO, EN_SYSTEM_PROMPT_NANO, selectAiProvider };`
)(() => null, () => '', () => '');

let pass = 0, fail = 0;
function check(name, actual, expected) {
  if (JSON.stringify(actual) === JSON.stringify(expected)) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name}\n       期待: ${JSON.stringify(expected)}\n       実際: ${JSON.stringify(actual)}`); }
}

const T = mod.EN_SYSTEM_PROMPT;
const A = mod.EN_SYSTEM_PROMPT_AUDIO;

console.log('== テキスト用（実機検証済みの前提を保っている）==');
check('音声は届いていない、が残っている', T.includes('音声は届いていません'), true);
check('発音に触れない、が残っている',     T.includes('発音については一切言及しないでください'), true);
check('出力に transcript が無い',         T.includes('"transcript"'), false);

console.log('== 音声用（テキスト用から派生できている）==');
check('組み立てに成功している',            typeof A, 'string');
check('前提が音声モードに差し替わっている', A.includes('## 重要な前提（音声モード）'), true);
check('音声は届いていない、が消えている',   A.includes('音声は届いていません'), false);
check('発音に触れない、が消えている',       A.includes('発音については一切言及しないでください'), false);
check('導入文が音声版になっている',         A.includes('その音声そのものと、参考として Chrome の音声認識結果があなたに渡されます。'), true);
check('人物像はそのまま共有',               A.includes('## あなたの人物像と口調'), true);
check('絶対のルールもそのまま共有',         A.includes('## 口調より優先される絶対のルール'), true);
check('見る観点もそのまま共有',             A.includes('## 見る観点'), true);
check('出力に transcript がある',           A.includes('"transcript"'), true);
check('出力に pronunciation がある',        A.includes('"pronunciation"'), true);
check('出力に recognition_doubt が残る',    A.includes('"recognition_doubt"'), true);
check('出力に targets がある',              A.includes('"targets"'), true);
check('狙いの表現の節も共有',               A.includes('## 今日の狙いの表現'), true);
check('テキスト用の出力にも targets',       T.includes('"targets"'), true);
check('出力節は 1 つだけ',                  A.split('## 出力').length - 1, 1);
check('前提節は 1 つだけ',                  A.split('## 重要な前提').length - 1, 1);

console.log('== プロバイダの能力 ==');
const gem  = mod.selectAiProvider({ geminiKey: 'k' });
const nano = mod.selectAiProvider({ geminiKey: '', nanoState: 'available' });
check('Gemini は音声に対応',            gem.supportsAudio, true);
check('Gemini に音声メソッドがある',    typeof gem.reviewEnglishAudio, 'function');
check('Nano は音声に対応しない',        !!nano.supportsAudio, false);
check('キー優先でも Nano 指定なら Nano', mod.selectAiProvider({ geminiKey: 'k', engine: 'nano', nanoState: 'available' }).id, 'nano');

console.log('');
console.log(`結果: ${pass} 件成功 / ${fail} 件失敗`);
process.exit(fail === 0 ? 0 : 1);
