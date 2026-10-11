// 拡張機能の english-core.js / phrase-core.js と、Android 用に移した android/core（Kotlin）が
// **同じ入力に同じ答えを返すか**を実際に突き合わせる。場面は parity_cases.mjs（Swift 版と共用）。
//
// 実行: node test/parity_android.mjs（プロジェクトルートから）
//       事前に (cd android && ./gradlew :core:installDist) が要る
//       JAVA_HOME は Android Studio 同梱の JBR でよい
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { payload, root, compare } from './parity_cases.mjs';

const probe = join(root, 'android', 'core', 'build', 'install', 'hg-probe', 'bin', 'hg-probe');
if (!existsSync(probe)) {
  console.error('NG: hg-probe（Kotlin）がありません。先に `cd android && ./gradlew :core:installDist` を実行してください。');
  process.exit(1);
}
const env = { ...process.env };
if (!env.JAVA_HOME) env.JAVA_HOME = '/Applications/Android Studio.app/Contents/jbr/Contents/Home';

let out;
try {
  out = execFileSync(probe, { input: payload, maxBuffer: 64 * 1024 * 1024, env }).toString();
} catch (err) {
  console.error('NG: hg-probe（Kotlin）を実行できません。');
  console.error(err.message);
  process.exit(1);
}
process.exit(compare(JSON.parse(out).results) === 0 ? 0 : 1);
