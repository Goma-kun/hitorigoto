// i18n: ブラウザの言語に応じた文言を返す／DOMへ流し込む
const T = (k, ...sub) => chrome.i18n.getMessage(k, sub.length ? sub : undefined) || k;
function applyI18n() {
  for (const el of document.querySelectorAll('[data-i18n]')) {
    const m = T(el.dataset.i18n);
    if (m) el.textContent = m;
  }
  for (const el of document.querySelectorAll('[data-i18n-title]')) {
    const m = T(el.dataset.i18nTitle);
    if (m) el.title = m;
  }
}

// ============================================================
// 状態
// ============================================================
let geminiKey   = '';
let isRecording = false;
let recogLang   = 'en-US';        // 聞き取る英語（en-US / en-GB。設定画面で変更可能）
let enginePref  = 'auto';         // AIエンジン設定（'auto' | 'nano'）
let nanoState   = 'unavailable';  // Chrome 内蔵 AI の利用可否（起動時に判定）
let transcript  = '';
let interimText = '';             // 確定前の認識結果（表示用・停止時に拾って確定させる）
let enSessions  = [];             // 過去のセッション（新しい順）
let enRecurring = [];             // 繰り返し出ている指摘
let enLatest    = null;           // 画面に出している直近のフィードバック
let enBusy      = false;
let enError     = '';

const DEFAULT_LANG = 'en-US';

// ============================================================
// ストレージ（実体の保存・読み出しは履歴層 history-store.js に集約）
// ============================================================
async function loadStorage() {
  const d = await chrome.storage.local.get(['hg_gemini_key', 'hg_lang', 'hg_engine']);
  geminiKey  = d.hg_gemini_key || '';
  recogLang  = d.hg_lang === 'en-GB' ? 'en-GB' : DEFAULT_LANG;
  enginePref = d.hg_engine === 'nano' ? 'nano' : 'auto';

  const h = await HistoryStore.load();
  transcript  = h.transcript;
  enSessions  = h.enSessions;
  enRecurring = h.enRecurring;
  // 前回のフィードバックは戻さない。開いた時点では常に「話してください」の状態にする
  enLatest = null;
}

function saveTranscript() {
  HistoryStore.saveTranscript(transcript);
}

// いま使う AI プロバイダ。null なら添削できない（設定への案内を出す）
function currentAi() {
  return selectAiProvider({ geminiKey, engine: enginePref, nanoState });
}

// ============================================================
// UI 要素
// ============================================================
const settingsBtn  = document.getElementById('settings-btn');
const tabSpeak     = document.getElementById('tab-speak');
const tabHistory   = document.getElementById('tab-history');
const panelSpeak   = document.getElementById('panel-speak');
const panelHistory = document.getElementById('panel-history');
const enLive       = document.getElementById('en-live');
const enFeedback   = document.getElementById('en-feedback');
const toggleBtn    = document.getElementById('toggle-btn');

// ============================================================
// パネル切り替え
// ============================================================
function switchPanel(id) {
  [tabSpeak, tabHistory].forEach(t => t.classList.remove('active'));
  panelSpeak.style.display   = 'none';
  panelHistory.style.display = 'none';

  if (id === 'speak') {
    panelSpeak.style.display = 'block';
    tabSpeak.classList.add('active');
    // 開いた時点では常に「話してください」の状態にする。
    // 読み返しは履歴タブから（指摘つきで全部残っている）
    enLatest = null;
    enError  = '';
    renderEnglish();
  } else if (id === 'history') {
    panelHistory.style.display = 'flex';   // column+gap レイアウトを効かせる（block だと gap が死ぬ）
    tabHistory.classList.add('active');
    renderHistory();
  }
}

// ============================================================
// 履歴パネルの部品
// ============================================================

// 履歴の本文。長いものは4行で畳んでおき、「全文」で開けるようにする
function historyBody(text) {
  const body = document.createElement('div');
  body.className = 'history-body';
  body.textContent = text;
  return body;
}

// カードを画面に入れたあとに呼ぶ。実際に畳まれているときだけボタンを出す
function addExpandBtn(body) {
  if (body.scrollHeight <= body.clientHeight + 1) return;

  const btn = document.createElement('button');
  btn.className = 'history-expand-btn';
  btn.textContent = T('btnExpand');
  btn.addEventListener('click', () => {
    const open = body.classList.toggle('expanded');
    btn.textContent = open ? T('btnCollapse') : T('btnExpand');
  });
  body.insertAdjacentElement('afterend', btn);
}

// ============================================================
// 録音制御（認識オブジェクトの生成・再起動は音声認識層 speech.js が持つ）
// ============================================================
const recognizer = SpeechCapture.createRecognizer({
  onStart:  () => onRecordingStarted(),
  onStop:   () => onRecordingStopped(),
  onResult: (interim, final) => onResult(interim, final),
  onError:  (code) => showToast(T('speechError') + code, 'error'),
});

function startRecording() {
  if (!SpeechCapture.supported()) { showToast(T('speechUnavailable'), 'error'); return; }
  recognizer.start(recogLang);
}

function stopRecording() {
  recognizer.stop();
}

function onRecordingStarted() {
  isRecording = true;
  toggleBtn.textContent = T('btnStop');
  toggleBtn.className = 'recording';

  enLatest = null;
  enError  = '';
  enLive.textContent = transcript;
  switchPanel('speak');
}

function onRecordingStopped() {
  isRecording = false;
  toggleBtn.textContent = T('btnStart');
  toggleBtn.className = 'idle';

  const pending = interimText.trim();
  if (pending) {
    transcript += pending + '\n';
    saveTranscript();
  }
  interimText = '';

  enLive.textContent = transcript;
  if (transcript.trim()) runEnglishFeedback();
}

function onResult(interim, final) {
  if (final) {
    transcript += final + '\n';
    interimText = '';
    saveTranscript();
  }
  if (interim) interimText = interim;
  enLive.textContent = transcript + interimText;
  panelSpeak.scrollTop = panelSpeak.scrollHeight;
}

// ============================================================
// 添削の実行
// ============================================================

// 添削のシステム指示・プロバイダ選択は AI 呼び出し層（ai-providers.js）にある。
// 純ロジック（parseFeedback・foldSessions など）は english-core.js にある。
// test/english_test.mjs はそちらを切り出して検証する

function todayStamp() {
  const d = new Date();
  const p = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

async function runEnglishFeedback() {
  const text = transcript.trim();
  if (!text) return;
  const ai = currentAi();
  if (!ai) { renderEnglish(); return; }

  enBusy  = true;
  enError = '';
  renderEnglish();

  try {
    // 応答の取得と JSON 解釈は AI 呼び出し層が行う。JSON として読めない応答はここまで来ない
    const fb = await ai.reviewEnglish(text, topRecurring(enRecurring));
    fb.engineId = ai.id;   // 表示用（端末内 AI のときは注記を出す）

    enSessions.unshift({
      id:             new Date().toISOString(),
      transcript:     text,
      corrected_text: fb.corrected_text,
      issues:         fb.issues,
      good:           fb.good,
    });
    enSessions  = foldSessions(enSessions);
    enRecurring = promoteRecurring(enRecurring, fb.issues, todayStamp());
    await HistoryStore.saveEnglish(enSessions, enRecurring);

    enLatest = fb;
    enBusy   = false;

    // 次の録音のために書き起こしだけ空にする。フィードバックは読み終わるまで残す
    transcript = '';
    saveTranscript();
    enLive.textContent = '';
    renderEnglish();
  } catch (err) {
    // 失敗したときは書き起こしを消さない（話した内容を失わせない）
    enBusy  = false;
    enError = err.code === 'denied' ? T('errDenied')
            : err.code === 'parse'  ? T('enParseError')
            : (err.message || T('unknownError'));
    renderEnglish();
    showToast(T('enError') + enError, 'error');
  }
}

// ============================================================
// フィードバックの表示
// ============================================================
function enNote(text, cls = '') {
  const el = document.createElement('div');
  el.className = 'en-note' + (cls ? ' ' + cls : '');
  el.textContent = text;
  return el;
}

function enSection(title) {
  const sec = document.createElement('section');
  sec.className = 'en-section';
  const h = document.createElement('div');
  h.className = 'en-section-title';
  h.textContent = title;
  sec.appendChild(h);
  return sec;
}

function enTypeLabel(type) {
  return T({ phrasing: 'typePhrasing', vocabulary: 'typeVocabulary', grammar: 'typeGrammar' }[type] || 'typePhrasing');
}

// AI が使えないときの案内。端末が Nano に対応していればワンクリックで設定へ誘導する
function renderNoAi() {
  const msg = (nanoState === 'downloadable' || nanoState === 'downloading')
    ? T('enSetupNano')   // モデルを落とせば使える端末
    : T('enNoAi');       // Nano 非対応 → キー設定の案内
  enFeedback.appendChild(enNote(msg));

  const btn = document.createElement('button');
  btn.className = 'en-setup-btn';
  btn.textContent = T('btnOpenSettings');
  btn.addEventListener('click', () => chrome.runtime.openOptionsPage());
  enFeedback.appendChild(btn);
}

function renderEnglish() {
  enFeedback.innerHTML = '';

  if (enBusy)       { enFeedback.appendChild(enNote(T('enAnalyzing'))); return; }
  if (!currentAi()) { renderNoAi(); return; }
  if (enError)      { enFeedback.appendChild(enNote(enError, 'en-error')); }

  const fb = enLatest;
  if (!fb) {
    if (!enError) enFeedback.appendChild(enNote(T('enHint')));
    // 話す前に、これまで繰り返し出ている癖を出しておく。
    // 「今日はここに気をつけて話す」の materials になる
    const recurring = topRecurring(enRecurring, 3);
    if (recurring.length > 0) {
      const sec = enSection(T('enRecurring'));
      const ul = document.createElement('ul');
      ul.className = 'en-recurring';
      recurring.forEach(r => {
        const li = document.createElement('li');
        li.textContent = `${r.text}（${T('enTimes', String(r.count))}）`;
        ul.appendChild(li);
      });
      sec.appendChild(ul);
      enFeedback.appendChild(sec);
    }
    enFeedback.appendChild(enNote(T('enNoPronunciation'), 'en-fineprint'));
    return;
  }

  // 表示順は good → issues → recurring → corrected_text
  if (fb.good) {
    const sec = enSection(T('enGood'));
    const p = document.createElement('p');
    p.className = 'en-good';
    p.textContent = fb.good;
    sec.appendChild(p);
    enFeedback.appendChild(sec);
  }

  {
    const sec = enSection(T('enIssues'));
    if (fb.issues.length === 0) {
      sec.appendChild(enNote(T('enNoIssues')));
    } else {
      fb.issues.forEach(it => {
        const card = document.createElement('div');
        card.className = 'en-issue';

        const badge = document.createElement('span');
        badge.className = 'en-badge en-badge-' + it.type;
        badge.textContent = enTypeLabel(it.type);

        const swap = document.createElement('div');
        swap.className = 'en-swap';
        const from = document.createElement('span');
        from.className = 'en-from';
        from.textContent = it.original;
        const arrow = document.createElement('span');
        arrow.className = 'en-arrow';
        arrow.textContent = '→';
        const to = document.createElement('span');
        to.className = 'en-to';
        to.textContent = it.suggestion;
        swap.append(from, arrow, to);

        card.appendChild(badge);
        card.appendChild(swap);
        if (it.reason) {
          const why = document.createElement('p');
          why.className = 'en-reason';
          why.textContent = it.reason;
          card.appendChild(why);
        }
        sec.appendChild(card);
      });
    }
    enFeedback.appendChild(sec);
  }

  if (fb.recurring.length > 0) {
    const sec = enSection(T('enRecurring'));
    const ul = document.createElement('ul');
    ul.className = 'en-recurring';
    fb.recurring.forEach(r => {
      const li = document.createElement('li');
      li.textContent = r;
      ul.appendChild(li);
    });
    sec.appendChild(ul);
    enFeedback.appendChild(sec);
  }

  // 音声認識が化けた箇所。指摘に混ざると「言っていないこと」を直されたように見えるので、
  // 別枠で事実だけ出す。発音の話にはしない（音声は AI に届いていない）
  if (fb.recognition_doubt.length > 0) {
    const sec = enSection(T('enDoubt'));
    const ul = document.createElement('ul');
    ul.className = 'en-doubt';
    fb.recognition_doubt.forEach(d => {
      const li = document.createElement('li');
      li.textContent = d;
      ul.appendChild(li);
    });
    sec.appendChild(ul);
    sec.appendChild(enNote(T('enDoubtNote'), 'en-fineprint'));
    enFeedback.appendChild(sec);
  }

  if (fb.corrected_text) {
    const sec = enSection(T('enCorrected'));
    const p = document.createElement('p');
    p.className = 'en-corrected';
    p.textContent = fb.corrected_text;
    sec.appendChild(p);

    const btn = document.createElement('button');
    btn.className = 'history-copy-btn';
    btn.textContent = T('btnCopy');
    btn.addEventListener('click', () => {
      navigator.clipboard.writeText(fb.corrected_text).then(() => {
        btn.textContent = T('btnCopied');
        setTimeout(() => { btn.textContent = T('btnCopy'); }, 1500);
      }).catch(() => showToast(T('copyFailed'), 'error'));
    });
    sec.appendChild(btn);
    enFeedback.appendChild(sec);
  }

  // 端末内 AI で処理したときは明示する（API より精度が下がることがあるため）
  if (fb.engineId === 'nano') {
    enFeedback.appendChild(enNote(T('enNanoNote'), 'en-fineprint'));
  }
  enFeedback.appendChild(enNote(T('enNoPronunciation'), 'en-fineprint'));
}

// ============================================================
// 履歴の表示
// ============================================================
function renderHistory() {
  panelHistory.innerHTML = '';

  const recurring = topRecurring(enRecurring);
  if (recurring.length > 0) {
    const card = document.createElement('div');
    card.className = 'history-card';

    const meta = document.createElement('div');
    meta.className = 'history-meta';
    meta.textContent = T('enRecurring');
    card.appendChild(meta);

    const ul = document.createElement('ul');
    ul.className = 'en-recurring';
    recurring.forEach(r => {
      const li = document.createElement('li');
      li.textContent = `${r.text}（${T('enTimes', String(r.count))}）`;
      ul.appendChild(li);
    });
    card.appendChild(ul);
    panelHistory.appendChild(card);
  }

  if (enSessions.length === 0) {
    panelHistory.appendChild(enNote(T('enHistoryEmpty')));
    return;
  }

  enSessions.forEach(s => {
    const card = document.createElement('div');
    card.className = 'history-card';

    const meta = document.createElement('div');
    meta.className = 'history-meta';
    const when = new Date(s.id);
    const label = isNaN(when) ? String(s.id)
      : when.toLocaleString('ja-JP', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' });
    meta.textContent = `${label}　${T('enIssueCount', String((s.issues || []).length))}`;
    card.appendChild(meta);

    if (s.folded) {
      const lines = (s.issues || []).map(it => it.suggestion).filter(Boolean);
      const body = historyBody(lines.length ? lines.join(' / ') : T('enFolded'));
      card.appendChild(body);
      const foldedBtn = enHistoryCopyBtn(s);
      if (foldedBtn) card.appendChild(foldedBtn);
      panelHistory.appendChild(card);
      addExpandBtn(body);
      return;
    }

    const body = historyBody(s.corrected_text || s.transcript || '');
    card.appendChild(body);

    // 修正版だけでなく、何を直したのかも履歴から見返せるようにする。
    // コピーは従来どおり修正版だけにして、音読用の使い方は変えない。
    if ((s.issues || []).length > 0) {
      const title = document.createElement('div');
      title.className = 'en-section-title';
      title.textContent = T('enIssues');
      card.appendChild(title);

      const issues = document.createElement('ul');
      issues.className = 'en-recurring';
      s.issues.forEach(it => {
        const li = document.createElement('li');
        li.textContent = `${it.original} → ${it.suggestion}${it.reason ? ` — ${it.reason}` : ''}`;
        issues.appendChild(li);
      });
      card.appendChild(issues);
    }

    const btn = enHistoryCopyBtn(s);
    if (btn) card.appendChild(btn);
    panelHistory.appendChild(card);
    addExpandBtn(body);
  });
}

// コピーの見出し。表示言語に合わせる
function enCopyLabels() {
  return {
    corrected: T('enLabelCorrected'),
    issues:    T('enIssues'),
    good:      T('enGood'),
    said:      T('enLabelSaid'),
    types: { phrasing: T('typePhrasing'), vocabulary: T('typeVocabulary'), grammar: T('typeGrammar') },
  };
}

// 履歴のコピーは指摘つき。あとから見返して使えるように、何を直されたのかも持ち出す
function enHistoryCopyBtn(session) {
  const text = buildSessionText(session, enCopyLabels());
  if (!text) return null;

  const btn = document.createElement('button');
  btn.className = 'history-copy-btn';
  btn.textContent = T('btnCopyWithIssues');
  btn.addEventListener('click', () => {
    navigator.clipboard.writeText(text).then(() => {
      btn.textContent = T('btnCopied');
      setTimeout(() => { btn.textContent = T('btnCopyWithIssues'); }, 1500);
    }).catch(() => showToast(T('copyFailed'), 'error'));
  });
  return btn;
}

// ============================================================
// トースト通知
// ============================================================
let toastTimer = null;
function showToast(msg, type = 'info') {
  let toast = document.getElementById('toast');
  if (!toast) {
    toast = document.createElement('div');
    toast.id = 'toast';
    const style = toast.style;
    style.position = 'fixed';
    style.bottom   = '70px';
    style.left     = '50%';
    style.transform = 'translateX(-50%)';
    style.padding  = '7px 14px';
    style.borderRadius = '8px';
    style.fontSize  = '12px';
    style.fontWeight = '700';
    style.zIndex   = '9999';
    style.pointerEvents = 'none';
    style.transition = 'opacity 0.3s';
    document.body.appendChild(toast);
  }
  const colors = { ok: ['#052e16','#4ade80'], error: ['#450a0a','#f87171'], info: ['#0f172a','#94a3b8'] };
  const [bg, fg] = colors[type] || colors.info;
  toast.style.background = bg;
  toast.style.color      = fg;
  toast.style.border     = `1px solid ${fg}44`;
  toast.textContent = msg;
  toast.style.opacity = '1';
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { toast.style.opacity = '0'; }, 2500);
}

// ============================================================
// ストレージ変更監視
// ============================================================
chrome.storage.onChanged.addListener((changes) => {
  if (changes.hg_gemini_key) {
    geminiKey = changes.hg_gemini_key.newValue || '';
    if (panelSpeak.style.display !== 'none' && !isRecording && !enBusy) renderEnglish();
  }
  // 設定画面で言語を変えたら即反映（録音中の場合は次回の録音から）
  if (changes.hg_lang) {
    recogLang = changes.hg_lang.newValue === 'en-GB' ? 'en-GB' : DEFAULT_LANG;
    if (recognizer.running) showToast(T('langChanged'), 'info');
  }
  // 設定画面で AI エンジンを変えたら即反映。DL 直後の場合もあるので利用可否を取り直す
  if (changes.hg_engine) {
    enginePref = changes.hg_engine.newValue === 'nano' ? 'nano' : 'auto';
    nanoAvailability().then(s => {
      nanoState = s;
      if (currentAi()?.id === 'nano') prewarmNano();
      if (panelSpeak.style.display !== 'none' && !isRecording && !enBusy) renderEnglish();
    });
  }
});

// ============================================================
// イベントリスナー
// ============================================================
toggleBtn.addEventListener('click', () => {
  if (!isRecording) startRecording();
  else stopRecording();
});

settingsBtn.addEventListener('click', () => chrome.runtime.openOptionsPage());

tabSpeak.addEventListener('click', () => {
  if (isRecording) return;   // 録音中の切り替えは受け付けない
  switchPanel('speak');
});
tabHistory.addEventListener('click', () => {
  if (isRecording) { showToast(T('lockedWhileRec'), 'info'); return; }
  switchPanel('history');
});

// ============================================================
// 初期化
// ============================================================
document.addEventListener('DOMContentLoaded', async () => {
  applyI18n();
  // Chrome 内蔵 AI の利用可否。ロードを待たせないため並行で取る
  const nanoCheck = nanoAvailability().then(s => { nanoState = s; });
  await loadStorage();
  await nanoCheck;
  // Nano を使う見込みなら、この時点でモデルのロード（初回約16秒）を始めておく。
  // 録音が終わってから待たせないための仕込み
  if (currentAi()?.id === 'nano') prewarmNano();
  enLive.textContent = transcript;
  switchPanel('speak');
});

// ヘッダーのバージョンバッジ。manifest の版をそのまま出す（表示と実体をずらさない）
const verBadge = document.getElementById('ver-badge');
if (verBadge && typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.getManifest) {
  verBadge.textContent = 'v' + chrome.runtime.getManifest().version;
}
