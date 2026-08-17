// ============================================================
// AI 呼び出し層（Nano / Gemini を同一インターフェースで差し替える）
// ============================================================
// まもるくんの ai-providers.js から独り言（英語添削）に必要な部分だけを切り出したもの。
// 添削プロンプト・Nano まわりの実装は 2026-08-16 の実機検証済みの文面を一字一句変えずに使う。
//
// 共通インターフェース:
//   provider.id … 'nano'（Chrome 内蔵 AI / Prompt API）| 'gemini'（BYOK）
//   provider.reviewEnglish(text, recurring) → Promise<feedback> parseFeedback 済みの形
//
// 失敗は Error を投げる。err.code で UI 側が文言を出し分ける:
//   'denied' … Gemini 403（プロジェクトに無料枠が割り当てられていない）
//   'parse'  … 応答が JSON として読めない
//
// 依存: english-core.js（parseFeedback / buildEnglishUserMessage）を先に読み込むこと

// ------------------------------------------------------------
// エンジンの選び方
// ------------------------------------------------------------
// engine（設定画面の「AIエンジン」・storage の hg_engine）:
//   'auto'（既定）… キーがあれば Gemini、無ければ Nano が使えるなら Nano
//   'nano'        … Nano が使える端末では常に Nano（Gemini との比較・試用向け）
// nanoState は起動時に nanoAvailability() で取った値を渡す（'available' 以外は Nano を使わない）
function selectAiProvider({ geminiKey, engine = 'auto', nanoState = 'unavailable' }) {
  const nanoOk = nanoState === 'available';
  if (engine === 'nano' && nanoOk) return createNanoProvider();
  if (geminiKey) return createGeminiProvider(geminiKey);
  if (nanoOk) return createNanoProvider();
  return null;
}

// ------------------------------------------------------------
// 英語添削のシステム指示（Nano / Gemini 共用…Gemini はこの長文版を使う）
// ------------------------------------------------------------
// 音声は届いていないため、発音には一切触れさせない。
// 触れさせるとテキストからの推測でもっともらしい嘘が返り、学習用途では有害になる。
const EN_SYSTEM_PROMPT = `あなたは英語学習者の「独り言」練習を見るコーチです。
学習者が英語で 3〜5 分ほど独り言を話し、その音声認識結果があなたに渡されます。

## 重要な前提

- あなたに届いているのは音声認識を通したテキストです。音声は届いていません。
- したがって **発音については一切言及しないでください。**
- 音声認識の誤りと、学習者本人の誤りは区別してください。
  文脈から見て明らかに聞き取り違いと分かる箇所（例：綴りは似ているが文脈に合わない語）は、
  文法や語彙の誤りとして扱わず、recognition_doubt に入れてください。

### 聞き取り違いを指摘に混ぜないための例

音声認識は、文脈に合わない語へ大きく化けることがあります。
**化けた語をそのまま「あなたの語彙の誤り」として指摘すると、言ってもいないことを
教えることになります。** 以下は学習者の誤りではありません。

例 1:
認識結果: a lot of English speakers introduce yourself way to improve the English skills
→ 意味が通らず、文脈上は recommend this way と言ったと考えられます。
   語彙の誤りとして指摘せず、recognition_doubt に入れてください。

例 2:
認識結果: I would like to use french fries and extractions next time
→ french fries（食べ物）は文脈に合いません。these expressions の聞き取り違いです。

例 3:
認識結果: I will definitely use this apple consistency consistency
→ this app consistently の聞き取り違いです。同じ語の繰り返しも認識の癖です。

判断の目安：**その語を実際に口に出したとは考えにくいほど文脈から外れている場合**は、
学習者の誤りではなく聞き取り違いとして扱ってください。
逆に、学習者が実際に言いそうな誤り（時制、冠詞、可算・不可算、前置詞、
take と get の選び違いなど）は、そのまま指摘して構いません。

## 見る観点（この 4 つだけ）

1. 不自然な言い回しと、その自然な代替
2. 語彙の選択（意味は通るが、その文脈ではより適切な語がある場合）
3. 文法の誤り
4. 繰り返し出ている癖（過去の指摘が渡されている場合はそれと照合する）

## 指摘の量

- 指摘は最大 5 件まで。多いと読まれません。
- 影響の大きいものから順に並べてください。
- 些細な誤り（冠詞の揺れ程度で意味が変わらないもの）は、他に指摘がないときだけ挙げてください。

## 出力

以下の JSON だけを返してください。前置き、説明、コードフェンスは付けないでください。

{
  "corrected_text": "修正版の全文。学習者が音読練習に使えるよう、自然な英語に整える",
  "issues": [
    {
      "type": "phrasing | vocabulary | grammar",
      "original": "学習者が言った表現",
      "suggestion": "代わりの表現",
      "reason": "なぜそちらが良いかを日本語で 1〜2 文"
    }
  ],
  "recurring": [
    "過去にも指摘された内容のうち、今回も出たものを日本語で 1 行ずつ"
  ],
  "recognition_doubt": [
    "音声認識の誤りと思われる箇所。原文の該当部分をそのまま入れる"
  ],
  "good": "今回よく書けていた点を日本語で 1 文。無理に褒めず、該当がなければ空文字にする"
}`;

// ============================================================
// Gemini API（BYOK・精度を上げたい人向け）
// ============================================================
function createGeminiProvider(key) {
  const MODEL = 'gemini-3.6-flash';

  async function call(body) {
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${key}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      }
    );
    const data = await res.json();
    if (!res.ok || data.error) {
      const msg = data?.error?.message || '';
      const err = new Error(msg);
      // 403 + "denied access" はキーの誤りではなく、プロジェクトに無料枠が割り当てられていないケース
      if (res.status === 403 && /denied access/i.test(msg)) err.code = 'denied';
      throw err;
    }
    return data?.candidates?.[0]?.content?.parts?.[0]?.text || '';
  }

  return {
    id: 'gemini',

    async reviewEnglish(text, recurring) {
      const raw = await call({
        systemInstruction: { parts: [{ text: EN_SYSTEM_PROMPT }] },
        contents: [{ role: 'user', parts: [{ text: buildEnglishUserMessage(text, recurring) }] }],
        generationConfig: { thinkingConfig: { thinkingLevel: "low" } },
        tools: []
      });
      // JSON として読めないものは返さない（前置きや回答をそのまま出すと嘘を教えることになる）
      const fb = parseFeedback(raw);
      if (!fb) { const err = new Error(''); err.code = 'parse'; throw err; }
      return fb;
    },
  };
}

// ============================================================
// Chrome 内蔵 AI（Prompt API / Gemini Nano）・キー不要の標準エンジン
// ============================================================
// 2026-08-16 の実機検証（Chrome 151 / M3 / 16GB）で確定した注意点:
// - LanguageModel.params() は無い。トークンは contextUsage / contextWindow（実測 9216）
// - モデル DL を伴う create() はユーザー操作必須 → 設定画面の切り替え操作を起点にする
// - 清書は既定 params が最良（temperature を下げると逆に文体が常体に書き換わる）
// - 添削は「suggestion は必ず英語」を明記しないと日本語訳に化ける
// - 初回セッション作成が約 16 秒 → ベースセッションを使い回し、clone() して使う

async function nanoAvailability() {
  if (typeof LanguageModel === 'undefined') return 'unavailable';
  try { return await LanguageModel.availability(); } catch { return 'unavailable'; }
}

// ベースセッションの使い回し。毎回 create すると初回 16 秒級のロードが走るため、
// 種類ごとに 1 本作って保持し、リクエストごとに clone() を使い捨てる
// （clone なら会話履歴が積もらず、コンテキストも汚れない）。
// キャッシュには Promise を入れる（プリウォームと本番が同時に走っても二重 create しない）
const nanoCache = { review: null };

function nanoBase(kind, createOpts) {
  if (!nanoCache[kind]) nanoCache[kind] = LanguageModel.create(createOpts);
  return nanoCache[kind];
}

async function nanoPrompt(kind, createOpts, input, promptOpts) {
  const base = await nanoBase(kind, createOpts);
  const session = base.clone ? await base.clone() : base;
  try {
    return await session.prompt(input, promptOpts);
  } catch (err) {
    // 失敗したベースは捨てて、次回作り直す
    try { base.destroy(); } catch {}
    nanoCache[kind] = null;
    throw err;
  } finally {
    if (session !== base) { try { session.destroy(); } catch {} }
  }
}

// パネルを開いた時点で Nano を使う見込みなら、録音している間にロードを済ませておく。
// 録音終了後に 16 秒待たせないための仕込み。失敗しても本番時に作り直すだけなので握りつぶす
function prewarmNano() {
  if (typeof LanguageModel === 'undefined') return;
  nanoBase('review', NANO_REVIEW_OPTS).catch(() => { nanoCache.review = null; });
}

// Nano 用の添削指示。Gemini 用の EN_SYSTEM_PROMPT と違い、小型モデル向けに短く、
// 「suggestion は必ず英語」を最優先ルールにしてある（書かないと日本語訳に化ける。実測）
const EN_SYSTEM_PROMPT_NANO = `あなたは英語学習者の「独り言」を添削するコーチです。音声認識されたテキストが渡されます。

CRITICAL RULES:
- "corrected_text" と "suggestion" は必ず英語で書く。日本語訳を書いてはいけない
- "reason" と "good" は日本語で 1 文
- "type" は phrasing / vocabulary / grammar のどれか 1 つだけ
- 発音には一切触れない（音声は届いていない）
- 指摘は最大 5 件。影響の大きい順
- 文脈に合わないほど不自然な語は音声認識の化けなので、指摘にせず recognition_doubt に原文のまま入れる

正しい issue の例:
{"type":"grammar","original":"I could not concentrate to development","suggestion":"I could not concentrate on development","reason":"concentrate は前置詞 on を取ります。"}

次の JSON オブジェクトだけを返す（前置き・コードフェンス禁止）:
{"corrected_text":"...","issues":[{"type":"...","original":"...","suggestion":"...","reason":"..."}],"recurring":[],"recognition_doubt":[],"good":"..."}`;

// parseFeedback が受け取れる形をそのままスキーマにしたもの（responseConstraint 用）
const NANO_REVIEW_SCHEMA = {
  type: 'object',
  required: ['corrected_text', 'issues'],
  properties: {
    corrected_text: { type: 'string' },
    issues: {
      type: 'array',
      maxItems: 5,
      items: {
        type: 'object',
        required: ['type', 'original', 'suggestion', 'reason'],
        properties: {
          type:       { type: 'string', enum: ['phrasing', 'vocabulary', 'grammar'] },
          original:   { type: 'string' },
          suggestion: { type: 'string' },
          reason:     { type: 'string' },
        },
      },
    },
    recurring:         { type: 'array', items: { type: 'string' } },
    recognition_doubt: { type: 'array', items: { type: 'string' } },
    good:              { type: 'string' },
  },
};

// セッション作成オプション。nanoPrompt と prewarmNano で同じものを使う
// temperature / topK は指定しない（既定が最良。低温は文体を常体に書き換える。実測）
const NANO_REVIEW_OPTS = {
  initialPrompts:  [{ role: 'system', content: EN_SYSTEM_PROMPT_NANO }],
  expectedInputs:  [{ type: 'text', languages: ['en', 'ja'] }],
  expectedOutputs: [{ type: 'text', languages: ['ja', 'en'] }],
};

function createNanoProvider() {
  return {
    id: 'nano',

    async reviewEnglish(text, recurring) {
      const raw = await nanoPrompt('review', NANO_REVIEW_OPTS,
        buildEnglishUserMessage(text, recurring), { responseConstraint: NANO_REVIEW_SCHEMA });
      const fb = parseFeedback(raw);
      if (!fb) { const err = new Error(''); err.code = 'parse'; throw err; }
      return fb;
    },
  };
}
