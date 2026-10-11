// 拡張機能の english-core.js / phrase-core.js と、iOS/Mac 用に移した ios/Sources/HitorigotoCore が
// **同じ入力に同じ答えを返すか**を実際に突き合わせる。場面は parity_cases.mjs（Android 版と共用）。
//
// 実行: node test/parity_swift_test.mjs（プロジェクトルートから）
//       事前に swift build --package-path ios が要る
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { payload, root, compare } from './parity_cases.mjs';

// ---- Swift へ流す ----
const bin = join(root, 'ios/.build/debug/hg-probe');
const out = JSON.parse(execFileSync(bin, { input: payload, maxBuffer: 64 * 1024 * 1024 }).toString());
process.exit(compare(out.results) === 0 ? 0 : 1);
