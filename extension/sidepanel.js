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
let enBusyAudio = false;          // 添削中の文言の出し分け（音声は少し時間がかかる）
let enError     = '';
let audioPref   = 'on';           // 録音した音声を Gemini に送るか（設定 hg_audio。'on' | 'off'）
let enPhrases   = [];             // 表現集（覚えたい表現・単語）
let enToday     = null;           // 今日の表現 { date, ids, results: { id: { r, as, note, judge } } }
let dailyTotal  = PH_DEFAULT_TOTAL; // 1 日に出す表現の数（設定 hg_daily_total）
let dailyNew    = PH_DEFAULT_NEW;   // そのうち新しい表現の上限（設定 hg_daily_new）
let phraseFilter = 'all';         // 表現集パネルの絞り込み
let phraseFormOpen = false;       // 追加フォームを開いているか
let flash       = null;           // カードで復習の進行状態 { cards, i, open }

const DEFAULT_LANG = 'en-US';

// ============================================================
// ストレージ（実体の保存・読み出しは履歴層 history-store.js に集約）
// ============================================================
async function loadStorage() {
  const d = await chrome.storage.local.get(['hg_gemini_key', 'hg_lang', 'hg_engine', 'hg_audio', 'hg_daily_total', 'hg_daily_new']);
  geminiKey  = d.hg_gemini_key || '';
  recogLang  = d.hg_lang === 'en-GB' ? 'en-GB' : DEFAULT_LANG;
  enginePref = d.hg_engine === 'nano' ? 'nano' : 'auto';
  audioPref  = d.hg_audio === 'off' ? 'off' : 'on';
  dailyTotal = clampInt(d.hg_daily_total, 1, 20, PH_DEFAULT_TOTAL);
  dailyNew   = clampInt(d.hg_daily_new, 0, 20, PH_DEFAULT_NEW);

  const h = await HistoryStore.load();
  transcript  = h.transcript;
  enSessions  = h.enSessions;
  enRecurring = h.enRecurring;
  // 読み込んだ表現は履歴から状態を組み立て直す（取り込んだ JSON の due や hits が古くても正しくなる）
  enPhrases   = h.enPhrases.map(p => rebuildPhrase(p));
  enToday     = h.enToday;
  // 前回のフィードバックは戻さない。開いた時点では常に「話してください」の状態にする
  enLatest = null;
}

function saveTranscript() {
  HistoryStore.saveTranscript(transcript);
}

function clampInt(v, min, max, fallback) {
  const n = parseInt(v, 10);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

// いま使う AI プロバイダ。null なら添削できない（設定への案内を出す）
function currentAi() {
  return selectAiProvider({ geminiKey, engine: enginePref, nanoState });
}

// 音声モード（生音を Gemini に渡して書き起こしと添削を一度にやる）が使える状態か。
// Gemini（キーあり）・設定オン・録音 API あり、の 3 つが揃ったときだけ
function audioEnabled() {
  const ai = currentAi();
  return !!(ai && ai.supportsAudio && audioPref === 'on' && AudioCapture.supported());
}

// ============================================================
// UI 要素
// ============================================================
const settingsBtn  = document.getElementById('settings-btn');
const tabSpeak     = document.getElementById('tab-speak');
const tabPhrases   = document.getElementById('tab-phrases');
const tabHistory   = document.getElementById('tab-history');
const panelSpeak   = document.getElementById('panel-speak');
const panelPhrases = document.getElementById('panel-phrases');
const panelHistory = document.getElementById('panel-history');
const enLive       = document.getElementById('en-live');
const enFeedback   = document.getElementById('en-feedback');
const toggleBtn    = document.getElementById('toggle-btn');

// ============================================================
// パネル切り替え
// ============================================================
function switchPanel(id) {
  [tabSpeak, tabPhrases, tabHistory].forEach(t => t.classList.remove('active'));
  panelSpeak.style.display   = 'none';
  panelPhrases.style.display = 'none';
  panelHistory.style.display = 'none';

  if (id === 'speak') {
    panelSpeak.style.display = 'block';
    tabSpeak.classList.add('active');
    // 開いた時点では常に「話してください」の状態にする。
    // 読み返しは履歴タブから（指摘つきで全部残っている）
    enLatest = null;
    enError  = '';
    renderEnglish();
  } else if (id === 'phrases') {
    panelPhrases.style.display = 'flex';
    tabPhrases.classList.add('active');
    renderPhrases();
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

// 生音の録音（音声モードのとき Web Speech と並行して回す）。実体は audio-capture.js
const audioRec = AudioCapture.create();

function startRecording() {
  if (!SpeechCapture.supported()) { showToast(T('speechUnavailable'), 'error'); return; }
  recognizer.start(recogLang);
  // 音声モードなら生音も録る。マイクが取れなければ従来どおりテキストだけで続ける
  if (audioEnabled()) {
    audioRec.start().catch(() => showToast(T('micUnavailable'), 'info'));
  }
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

async function onRecordingStopped() {
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
  // 生音を締める。録っていなければ null。音声があれば Chrome の認識結果が空でも添削できる
  const blob = await audioRec.stop();
  if (transcript.trim() || blob) runEnglishFeedback(blob);
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

// blob は録音した生音（音声モードのときだけ）。無ければテキストだけで添削する
async function runEnglishFeedback(blob = null) {
  const text = transcript.trim();
  const ai = currentAi();
  if (!ai) { renderEnglish(); return; }
  const useAudio = !!(blob && ai.supportsAudio && audioPref === 'on');
  if (!text && !useAudio) return;

  enBusy      = true;
  enBusyAudio = useAudio;
  enError     = '';
  renderEnglish();

  // 今日の表現。Gemini には「使えたか判定して」と一緒に渡す（Nano は小型なので渡さず、文字の照合だけで判定する）
  const targetCards = todayCards();
  const extra = ai.id === 'gemini' ? buildTargetsSection(targetCards) : '';

  try {
    // 応答の取得と JSON 解釈は AI 呼び出し層が行う。JSON として読めない応答はここまで来ない
    let fb;
    if (useAudio) {
      try {
        fb = await ai.reviewEnglishAudio(blob, text, topRecurring(enRecurring), extra);
        // 音声に聞き取れる発話が無かった（無音・雑音）。AI が作った結果を出さない
        if (!fb.transcript) { const err = new Error(''); err.code = 'silent'; throw err; }
        fb.audio = true;
      } catch (err) {
        // 音声で失敗しても、テキストがあればそちらで添削する（話した内容を無駄にしない）。
        // キーの問題（denied）はテキストでも同じ結果なので退避しない
        if (!text || err.code === 'denied') throw err;
        showToast(T(err.code === 'silent' ? 'enAudioSilent' : 'enAudioFallback'), 'info');
        enBusyAudio = false;
        renderEnglish();
        fb = await ai.reviewEnglish(text, topRecurring(enRecurring), extra);
      }
    } else {
      fb = await ai.reviewEnglish(text, topRecurring(enRecurring), extra);
    }
    fb.engineId = ai.id;   // 表示用（端末内 AI のときは注記を出す）

    // 音声モードでは AI の書き起こし（実際に言ったこと）を本文にし、Chrome の結果は参考として別に残す
    const said = (fb.audio && fb.transcript) ? fb.transcript : text;
    const session = {
      id:             new Date().toISOString(),
      transcript:     said,
      corrected_text: fb.corrected_text,
      issues:         fb.issues,
      good:           fb.good,
    };
    if (fb.audio && fb.transcript && text && text !== fb.transcript) session.asr_transcript = text;
    if (fb.pronunciation && fb.pronunciation.length > 0) session.pronunciation = fb.pronunciation;

    // 今日の表現が出たかを判定して記録する。AI の判定（音声を聞いている）があればそちらを優先
    if (targetCards.length > 0) {
      const judged = mergeAiTargets(judgePhrases(targetCards, said), targetCards, fb.targets || []);
      recordTodayResults(judged);
      session.targets = judged.map(j => {
        const c = targetCards.find(x => x.id === j.id);
        return { phrase: c ? c.phrase : '', r: j.result, as: j.asSaid || '' };
      });
      fb.targetsJudged = judged;
    }
    enSessions.unshift(session);
    enSessions  = foldSessions(enSessions);
    enRecurring = promoteRecurring(enRecurring, fb.issues, todayStamp());
    await HistoryStore.saveEnglish(enSessions, enRecurring);
    if (targetCards.length > 0) await HistoryStore.savePhrases(enPhrases, enToday);

    enLatest = fb;
    enBusy   = false;
    enBusyAudio = false;

    // 次の録音のために書き起こしだけ空にする。フィードバックは読み終わるまで残す
    transcript = '';
    saveTranscript();
    enLive.textContent = '';
    renderEnglish();
  } catch (err) {
    // 失敗したときは書き起こしを消さない（話した内容を失わせない）
    enBusy  = false;
    enBusyAudio = false;
    enError = err.code === 'denied' ? T('errDenied')
            : err.code === 'parse'  ? T('enParseError')
            : err.code === 'audio'  ? T('enAudioError')
            : err.code === 'silent' ? T('enNothingHeard')
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

  if (enBusy)       { enFeedback.appendChild(enNote(T(enBusyAudio ? 'enAnalyzingAudio' : 'enAnalyzing'))); return; }
  if (!currentAi()) { renderNoAi(); return; }
  if (enError)      { enFeedback.appendChild(enNote(enError, 'en-error')); }

  const fb = enLatest;
  if (!fb) {
    if (!enError) enFeedback.appendChild(enNote(T('enHint')));
    // 今日使ってみる表現。話す前に目を通しておく（表現プールの「今日の 6 個」と同じ役割）
    enFeedback.appendChild(renderTodayCard());
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
    // 音声モードなら「停止すると音声を送る」と先に伝えておく（送ることを隠さない）
    enFeedback.appendChild(enNote(T(audioEnabled() ? 'enAudioHint' : 'enNoPronunciation'), 'en-fineprint'));
    return;
  }

  // 表示順は good → 今日の表現の結果 → issues → recurring → corrected_text
  if (fb.good) {
    const sec = enSection(T('enGood'));
    const p = document.createElement('p');
    p.className = 'en-good';
    p.textContent = fb.good;
    sec.appendChild(p);
    enFeedback.appendChild(sec);
  }

  if ((fb.targetsJudged || []).length > 0) {
    enFeedback.appendChild(renderTodayResultCard(fb.targetsJudged));
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
        // 教わった表現を表現集に入れる（1 タップ）。入れたものは「入れた」に変わる
        card.appendChild(phraseAddBtn(it));
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

  // 発音が原因で別の語に聞こえた箇所（音声モードだけ入る）。
  // 左が言おうとした語、右がそう聞こえた語。誤りの赤ではなく、伝わらなかったの琥珀色で出す
  if ((fb.pronunciation || []).length > 0) {
    const sec = enSection(T('enPronunciation'));
    fb.pronunciation.forEach(it => {
      const card = document.createElement('div');
      card.className = 'en-issue';

      const swap = document.createElement('div');
      swap.className = 'en-swap';
      const said = document.createElement('span');
      said.className = 'en-said';
      said.textContent = it.said;
      const arrow = document.createElement('span');
      arrow.className = 'en-arrow';
      arrow.textContent = '→';
      const heard = document.createElement('span');
      heard.className = 'en-heard';
      heard.textContent = it.heard_as;
      swap.append(said, arrow, heard);
      card.appendChild(swap);

      if (it.note) {
        const why = document.createElement('p');
        why.className = 'en-reason';
        why.textContent = it.note;
        card.appendChild(why);
      }
      sec.appendChild(card);
    });
    sec.appendChild(enNote(T('enPronNote'), 'en-fineprint'));
    enFeedback.appendChild(sec);
  }

  // 音声認識が化けた箇所。指摘に混ざると「言っていないこと」を直されたように見えるので、
  // 別枠で事実だけ出す。テキストモードでは発音の話にしない（音声は AI に届いていない）。
  // 音声モードでは「音声では言えていた」と言い切れるので、注記を出し分ける
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
    sec.appendChild(enNote(T(fb.audio ? 'enDoubtNoteAudio' : 'enDoubtNote'), 'en-fineprint'));
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

  // 音声モードでは、AI が音声から書き起こした「実際に言ったこと」を見せる。
  // 画面に流れていた Chrome の認識結果とどこが違うかを、本人が自分で確かめられるように
  if (fb.audio && fb.transcript) {
    const sec = enSection(T('enHeard'));
    const p = document.createElement('p');
    p.className = 'en-heard-text';
    p.textContent = fb.transcript;
    sec.appendChild(p);
    enFeedback.appendChild(sec);
  }

  // 端末内 AI で処理したときは明示する（API より精度が下がることがあるため）
  if (fb.engineId === 'nano') {
    enFeedback.appendChild(enNote(T('enNanoNote'), 'en-fineprint'));
  }
  enFeedback.appendChild(enNote(T(fb.audio ? 'enAudioNote' : 'enNoPronunciation'), 'en-fineprint'));
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
        li.textContent = `${it.original} → ${it.suggestion}${it.reason ? ` — ${it.reason}` : ''} `;
        li.appendChild(phraseAddBtn(it));
        issues.appendChild(li);
      });
      card.appendChild(issues);
    }

    // その日の「今日の表現」がどうだったか（◎△✗−）
    if ((s.targets || []).length > 0) {
      const title = document.createElement('div');
      title.className = 'en-section-title';
      title.textContent = T('phTodayResult');
      card.appendChild(title);
      const ul = document.createElement('ul');
      ul.className = 'en-recurring';
      s.targets.forEach(t => {
        const li = document.createElement('li');
        li.textContent = `${PH_MARK[t.r] || ''} ${t.phrase}${t.as && t.r !== 'hit' ? `（${t.as}）` : ''}`;
        ul.appendChild(li);
      });
      card.appendChild(ul);
    }

    // 音声モードで拾った「発音で伝わらなかった箇所」。無いセッションでは出さない
    if ((s.pronunciation || []).length > 0) {
      const title = document.createElement('div');
      title.className = 'en-section-title';
      title.textContent = T('enPronunciation');
      card.appendChild(title);

      const ul = document.createElement('ul');
      ul.className = 'en-recurring';
      s.pronunciation.forEach(it => {
        const li = document.createElement('li');
        li.textContent = `${it.said} → ${it.heard_as}${it.note ? ` — ${it.note}` : ''}`;
        ul.appendChild(li);
      });
      card.appendChild(ul);
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
    pron:      T('enPronunciation'),
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
  // 音声を送るかの設定。次の録音から効く（録音中に切っても、今回の分は送らずに終える）
  if (changes.hg_audio) {
    audioPref = changes.hg_audio.newValue === 'off' ? 'off' : 'on';
    if (panelSpeak.style.display !== 'none' && !isRecording && !enBusy) renderEnglish();
  }
  // 毎日の表現の数。次に選ぶときから効く
  if (changes.hg_daily_total || changes.hg_daily_new) {
    if (changes.hg_daily_total) dailyTotal = clampInt(changes.hg_daily_total.newValue, 1, 20, PH_DEFAULT_TOTAL);
    if (changes.hg_daily_new)   dailyNew   = clampInt(changes.hg_daily_new.newValue, 0, 20, PH_DEFAULT_NEW);
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
tabPhrases.addEventListener('click', () => {
  if (isRecording) { showToast(T('lockedWhileRec'), 'info'); return; }
  switchPanel('phrases');
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

// ============================================================
// 表現集と「今日の表現」
// ============================================================
// 純ロジック（選び方・判定・次の予定）は phrase-core.js。ここは画面と保存だけ

const PH_MARK = { hit: '◎', partial: '△', miss: '✗', skip: '−' };
const PH_CYCLE = ['hit', 'partial', 'miss', 'skip'];   // 結果ボタンをタップしたときの順

// 今日の表現。日をまたいでいたら選び直し、決めてある分は保つ。見送りや削除で空いた枠は埋める
function todayCards() {
  const today = todayStamp();
  const fixed = (enToday && enToday.date === today) ? (enToday.ids || []) : [];
  const cards = pickTodayPhrases(enPhrases, today, { total: dailyTotal, maxNew: dailyNew, fixedIds: fixed });
  const ids = cards.map(c => c.id);
  const changed = !enToday || enToday.date !== today || JSON.stringify(enToday.ids || []) !== JSON.stringify(ids);
  if (changed) {
    enToday = { date: today, ids, results: (enToday && enToday.date === today) ? (enToday.results || {}) : {} };
    HistoryStore.savePhrases(enPhrases, enToday);
  }
  return cards;
}

function todayResult(id) {
  return (enToday && enToday.results && enToday.results[id]) || null;
}

// 判定結果を今日の記録と表現集の両方に入れる。
// 同じ日に 2 回話したときは良い方を残す（◎ を ✗ で上書きしない）。手で直したものは自動判定で上書きしない
function recordTodayResults(judged) {
  const today = todayStamp();
  if (!enToday || enToday.date !== today) enToday = { date: today, ids: [], results: {} };
  const rank = { hit: 3, partial: 2, miss: 1, skip: 0 };
  for (const j of judged) {
    const cur = todayResult(j.id);
    if (cur && cur.judge === 'manual') continue;
    if (cur && rank[cur.r] > rank[j.result]) continue;
    enToday.results[j.id] = { r: j.result, as: j.asSaid || '', note: j.note || '', judge: j.judge };
    applyPhraseResult(j.id, j.result, j.asSaid || '');
  }
}

function applyPhraseResult(id, result, asSaid) {
  const today = todayStamp();
  const i = enPhrases.findIndex(p => p.id === id);
  if (i < 0) return;
  enPhrases[i] = setSpeechResult(enPhrases[i], today, result, asSaid);
}

// 結果ボタンをタップして直す（◎→△→✗→−→◎）
function cycleTodayResult(id) {
  const cur = todayResult(id);
  const next = PH_CYCLE[(PH_CYCLE.indexOf(cur ? cur.r : 'skip') + 1) % PH_CYCLE.length];
  enToday.results[id] = { ...(cur || {}), r: next, judge: 'manual' };
  applyPhraseResult(id, next, cur ? cur.as : '');
  HistoryStore.savePhrases(enPhrases, enToday);
  // 履歴の最新セッションにも反映しておく（見返したときに画面と食い違わないように）
  const s = enSessions[0];
  if (s && Array.isArray(s.targets)) {
    const card = enPhrases.find(p => p.id === id);
    const t = card && s.targets.find(x => x.phrase === card.phrase);
    if (t) { t.r = next; HistoryStore.saveEnglish(enSessions, enRecurring); }
  }
}

// 「見送り」: 今日の話に合わなかった表現を外す。責めないので回数に数えず、2 日あけて戻る
function skipToday(id) {
  applyPhraseResult(id, 'skip', '');
  if (enToday) {
    enToday.ids = (enToday.ids || []).filter(x => x !== id);
    delete enToday.results[id];
  }
  HistoryStore.savePhrases(enPhrases, enToday);
  renderEnglish();
}

function phraseDueLabel(card, today) {
  if (card.status === 'graduated') return { text: T('phGraduated'), cls: 'grad' };
  if (!card.due) return { text: '', cls: '' };
  const n = phDaysBetween(today, card.due);
  if (n <= 0) return { text: n < 0 ? T('phOverdue', String(-n)) : T('phDueToday'), cls: n < 0 ? 'overdue' : 'today' };
  if (n === 1) return { text: T('phDueTomorrow'), cls: '' };
  return { text: T('phDueInDays', String(n)), cls: '' };
}

// 話す前に出す「今日の表現」カード
function renderTodayCard() {
  const sec = enSection(T('phToday'));
  const cards = todayCards();

  if (enPhrases.length === 0 || cards.length === 0) {
    sec.appendChild(enNote(T(enPhrases.length === 0 ? 'phTodayEmptyNoPhrases' : 'phTodayEmptyAllDone')));
    const btn = document.createElement('button');
    btn.className = 'en-setup-btn';
    btn.textContent = T('phGoAdd');
    btn.addEventListener('click', () => switchPanel('phrases'));
    sec.appendChild(btn);
    return sec;
  }

  cards.forEach(c => {
    const row = document.createElement('div');
    row.className = 'ph-today-row';

    const text = document.createElement('div');
    text.className = 'ph-today-text';
    const ph = document.createElement('div');
    ph.className = 'ph-phrase';
    ph.textContent = c.phrase;
    text.appendChild(ph);
    if (c.meaning || c.note) {
      const m = document.createElement('div');
      m.className = 'ph-meaning';
      m.textContent = c.meaning || `✗ ${c.note}`;
      text.appendChild(m);
    }
    const marks = phraseMarks(c);
    if (marks) {
      const mk = document.createElement('div');
      mk.className = 'ph-meta';
      const sp = document.createElement('span');
      sp.className = 'ph-marks';
      sp.textContent = marks;
      mk.appendChild(sp);
      text.appendChild(mk);
    }

    const tag = document.createElement('span');
    const last = lastSpeechResult(c);
    if (isNewPhrase(c)) { tag.className = 'ph-today-tag fresh'; tag.textContent = T('phTagNew'); }
    else if (last === 'miss' || last === 'partial') { tag.className = 'ph-today-tag retry'; tag.textContent = T('phTagRetry'); }
    else { tag.className = 'ph-today-tag'; tag.textContent = T('phTagReturn'); }

    const skip = document.createElement('button');
    skip.className = 'ph-btn plain small';
    skip.textContent = T('phSkip');
    skip.title = T('phSkipTip');
    skip.addEventListener('click', () => skipToday(c.id));

    row.append(text, tag, skip);
    sec.appendChild(row);
  });

  const foot = document.createElement('div');
  foot.className = 'ph-hint';
  foot.textContent = T('phTodayHint', String(cards.length));
  sec.appendChild(foot);
  return sec;
}

// 添削のあとに出す「今日の表現の結果」カード。記号をタップして直せる
function renderTodayResultCard(judged) {
  const sec = enSection(T('phTodayResult'));
  judged.forEach(j => {
    const card = enPhrases.find(p => p.id === j.id);
    if (!card) return;
    const row = document.createElement('div');
    row.className = 'ph-today-row';

    const btn = document.createElement('button');
    const paint = () => {
      const r = (todayResult(j.id) || { r: j.result }).r;
      btn.className = 'ph-mark-btn ' + r;
      btn.textContent = PH_MARK[r] || '';
      btn.title = T('phMarkTip');
    };
    paint();
    btn.addEventListener('click', () => { cycleTodayResult(j.id); paint(); });

    const text = document.createElement('div');
    text.className = 'ph-today-text';
    const ph = document.createElement('div');
    ph.className = 'ph-phrase';
    ph.textContent = card.phrase;
    text.appendChild(ph);
    const res = todayResult(j.id) || j;
    const as = res.as !== undefined ? res.as : j.asSaid;
    if (as && phraseKey(as) !== phraseKey(card.phrase)) {
      const s = document.createElement('div');
      s.className = 'ph-as-said';
      s.textContent = T('phAsSaid') + ' ';
      const b = document.createElement('b');
      b.textContent = as;
      s.appendChild(b);
      text.appendChild(s);
    }
    const note = res.note || j.note;
    if (note) {
      const n = document.createElement('div');
      n.className = 'ph-as-said';
      n.textContent = note;
      text.appendChild(n);
    }
    row.append(btn, text);
    sec.appendChild(row);
  });
  sec.appendChild(enNote(T('phResultHint'), 'en-fineprint'));
  return sec;
}

// 指摘の「代わりの表現」を表現集に入れるボタン。入れてあれば押せない表示にする
function phraseAddBtn(issue) {
  const btn = document.createElement('button');
  btn.className = 'ph-add-btn';
  const exists = !!findPhrase(enPhrases, issue.suggestion);
  btn.textContent = exists ? T('phAdded') : T('phAddToList');
  btn.disabled = exists;
  btn.addEventListener('click', async () => {
    const card = makePhrase({
      phrase:  issue.suggestion,
      kind:    issue.type === 'vocabulary' ? 'word' : 'phrase',
      source:  'issue',
      note:    issue.original || '',
      today:   todayStamp(),
    });
    const r = addPhrases(enPhrases, [card]);
    enPhrases = trimPhrases(r.list);
    await HistoryStore.savePhrases(enPhrases);
    btn.textContent = T('phAdded');
    btn.disabled = true;
    showToast(T('phAddedToast'), 'ok');
  });
  return btn;
}

// ---------- 表現集パネル ----------
function renderPhrases() {
  panelPhrases.innerHTML = '';
  if (flash) { renderFlash(); return; }
  const today = todayStamp();
  const cards = todayCards();
  const todayIds = new Set(cards.map(c => c.id));

  // 件数
  const st = phraseStats(enPhrases);
  const stats = document.createElement('div');
  stats.className = 'ph-stats';
  [['phStatActive', st.active], ['phStatFresh', st.fresh], ['phStatGraduated', st.graduated]].forEach(([k, n]) => {
    const sp = document.createElement('span');
    sp.textContent = T(k) + ' ';
    const b = document.createElement('b');
    b.textContent = String(n);
    sp.appendChild(b);
    stats.appendChild(sp);
  });
  panelPhrases.appendChild(stats);

  // 操作
  const bar = document.createElement('div');
  bar.className = 'ph-toolbar';
  const addBtn = document.createElement('button');
  addBtn.className = 'ph-btn primary';
  addBtn.textContent = T('phBtnAdd');
  addBtn.addEventListener('click', () => { phraseFormOpen = !phraseFormOpen; renderPhrases(); if (phraseFormOpen) document.getElementById('ph-in-phrase')?.focus(); });
  const flashBtn = document.createElement('button');
  flashBtn.className = 'ph-btn';
  flashBtn.textContent = T('phBtnFlash');
  flashBtn.addEventListener('click', startFlash);
  bar.append(addBtn, flashBtn);
  panelPhrases.appendChild(bar);

  // 追加フォーム
  const form = document.createElement('div');
  form.className = 'ph-form' + (phraseFormOpen ? ' open' : '');
  const inPhrase = document.createElement('input');
  inPhrase.id = 'ph-in-phrase';
  inPhrase.placeholder = T('phPlaceholderPhrase');
  inPhrase.autocomplete = 'off';
  inPhrase.spellcheck = false;
  const inMeaning = document.createElement('input');
  inMeaning.placeholder = T('phPlaceholderMeaning');
  inMeaning.autocomplete = 'off';
  const row = document.createElement('div');
  row.className = 'ph-form-row';
  const kind = document.createElement('select');
  [['phrase', 'phKindPhrase'], ['word', 'phKindWord']].forEach(([v, k]) => {
    const o = document.createElement('option');
    o.value = v; o.textContent = T(k);
    kind.appendChild(o);
  });
  const submit = document.createElement('button');
  submit.className = 'ph-btn primary';
  submit.textContent = T('phBtnSave');
  const doAdd = async () => {
    const card = makePhrase({ phrase: inPhrase.value, meaning: inMeaning.value, kind: kind.value, today });
    if (!card) { inPhrase.focus(); return; }
    const r = addPhrases(enPhrases, [card]);
    if (r.added === 0) { showToast(T('phDuplicate'), 'info'); return; }
    enPhrases = trimPhrases(r.list);
    await HistoryStore.savePhrases(enPhrases);
    showToast(T('phAddedToast'), 'ok');
    inPhrase.value = ''; inMeaning.value = '';
    renderPhrases();
    document.getElementById('ph-in-phrase')?.focus();
  };
  submit.addEventListener('click', doAdd);
  [inPhrase, inMeaning].forEach(el => el.addEventListener('keydown', e => { if (e.key === 'Enter') doAdd(); }));
  row.append(kind, submit);

  const bulkToggle = document.createElement('button');
  bulkToggle.className = 'ph-btn plain small';
  bulkToggle.textContent = T('phBulkToggle');
  const bulk = document.createElement('div');
  bulk.style.display = 'none';
  bulk.className = 'ph-form open';
  const ta = document.createElement('textarea');
  ta.placeholder = T('phBulkPlaceholder');
  ta.spellcheck = false;
  const bulkBtn = document.createElement('button');
  bulkBtn.className = 'ph-btn primary';
  bulkBtn.textContent = T('phBulkSave');
  bulkBtn.addEventListener('click', async () => {
    const items = parsePhraseLines(ta.value).map(x => makePhrase({ ...x, kind: kind.value, today })).filter(Boolean);
    const r = addPhrases(enPhrases, items);
    enPhrases = trimPhrases(r.list);
    await HistoryStore.savePhrases(enPhrases);
    showToast(T('phBulkDone', String(r.added)), 'ok');
    ta.value = '';
    renderPhrases();
  });
  const bulkHint = document.createElement('p');
  bulkHint.className = 'ph-hint';
  bulkHint.textContent = T('phBulkHint');
  bulk.append(ta, bulkHint, bulkBtn);
  bulkToggle.addEventListener('click', () => { bulk.style.display = bulk.style.display === 'none' ? 'flex' : 'none'; });

  form.append(inPhrase, inMeaning, row, bulkToggle, bulk);
  panelPhrases.appendChild(form);

  // 絞り込み
  const chips = document.createElement('div');
  chips.className = 'ph-chips';
  [['all', 'phFilterAll'], ['today', 'phFilterToday'], ['active', 'phFilterActive'], ['fresh', 'phFilterFresh'], ['graduated', 'phFilterGraduated'], ['word', 'phFilterWord']].forEach(([v, k]) => {
    const b = document.createElement('button');
    b.className = 'ph-chip' + (phraseFilter === v ? ' active' : '');
    b.textContent = T(k);
    b.addEventListener('click', () => { phraseFilter = v; renderPhrases(); });
    chips.appendChild(b);
  });
  panelPhrases.appendChild(chips);

  // 一覧（期日が近い順。卒業は最後）
  const list = document.createElement('div');
  list.className = 'ph-list';
  const shown = enPhrases.filter(p => {
    switch (phraseFilter) {
      case 'today':     return todayIds.has(p.id);
      case 'active':    return p.status === 'active' && !isNewPhrase(p);
      case 'fresh':     return p.status === 'active' && isNewPhrase(p);
      case 'graduated': return p.status === 'graduated';
      case 'word':      return p.kind === 'word';
      default:          return true;
    }
  }).sort((a, b) => {
    const ga = a.status === 'graduated' ? 1 : 0, gb = b.status === 'graduated' ? 1 : 0;
    if (ga !== gb) return ga - gb;
    if (ga) return String(b.added).localeCompare(String(a.added));
    return String(a.due || '').localeCompare(String(b.due || '')) || String(b.added).localeCompare(String(a.added));
  });

  if (enPhrases.length === 0) {
    list.appendChild(enNote(T('phEmpty')));
  } else if (shown.length === 0) {
    list.appendChild(enNote(T('phEmptyFilter')));
  }

  shown.forEach(p => {
    const card = document.createElement('div');
    card.className = 'ph-card' + (p.status === 'graduated' ? ' graduated' : '') + (todayIds.has(p.id) ? ' today' : '');

    const head = document.createElement('div');
    head.className = 'ph-head';
    const ph = document.createElement('div');
    ph.className = 'ph-phrase';
    ph.textContent = p.phrase;
    head.appendChild(ph);
    if (p.kind === 'word') {
      const k = document.createElement('span');
      k.className = 'ph-kind word';
      k.textContent = T('phKindWord');
      head.appendChild(k);
    }
    card.appendChild(head);

    if (p.meaning || p.note) {
      const m = document.createElement('div');
      m.className = 'ph-meaning';
      m.textContent = p.meaning || `✗ ${p.note}`;
      card.appendChild(m);
    }

    const meta = document.createElement('div');
    meta.className = 'ph-meta';
    const marks = document.createElement('span');
    marks.className = 'ph-marks';
    marks.textContent = phraseMarks(p) || T('phNotYet');
    meta.appendChild(marks);
    const due = phraseDueLabel(p, today);
    if (due.text) {
      const d = document.createElement('span');
      d.className = 'ph-due ' + due.cls;
      d.textContent = due.text;
      meta.appendChild(d);
    }
    card.appendChild(meta);

    const actions = document.createElement('div');
    actions.className = 'ph-actions';
    const tog = document.createElement('button');
    tog.className = 'ph-btn plain small';
    tog.textContent = T(p.status === 'graduated' ? 'phBtnUngraduate' : 'phBtnGraduate');
    tog.addEventListener('click', async () => {
      const i = enPhrases.findIndex(x => x.id === p.id);
      if (i < 0) return;
      enPhrases[i] = setManualStatus(enPhrases[i], p.status === 'graduated' ? 'active' : 'graduated', today);
      await HistoryStore.savePhrases(enPhrases);
      renderPhrases();
    });
    const del = document.createElement('button');
    del.className = 'ph-btn plain small';
    del.textContent = T('phBtnDelete');
    let armed = null;
    del.addEventListener('click', async () => {
      if (!armed) {
        del.textContent = T('phBtnDeleteConfirm');
        del.classList.add('danger');
        armed = setTimeout(() => { armed = null; del.textContent = T('phBtnDelete'); del.classList.remove('danger'); }, 3000);
        return;
      }
      clearTimeout(armed);
      enPhrases = enPhrases.filter(x => x.id !== p.id);
      if (enToday) { enToday.ids = (enToday.ids || []).filter(x => x !== p.id); delete enToday.results[p.id]; }
      await HistoryStore.savePhrases(enPhrases, enToday);
      renderPhrases();
    });
    actions.append(tog, del);
    card.appendChild(actions);
    list.appendChild(card);
  });
  panelPhrases.appendChild(list);

  const note = document.createElement('p');
  note.className = 'ph-hint';
  note.textContent = T('phRuleNote');
  panelPhrases.appendChild(note);
}

// ---------- カードで復習（意味を見て、言えるか自分で確かめる） ----------
// 言えなかったものだけ翌日の「今日の表現」に戻る。言えただけでは卒業に近づかない
function startFlash() {
  const today = todayStamp();
  const cards = enPhrases
    .filter(p => p.status === 'active' && p.meaning)
    .sort((a, b) => String(a.due || '').localeCompare(String(b.due || '')));
  if (cards.length === 0) { showToast(T('phFlashNone'), 'info'); return; }
  flash = { cards, i: 0, open: false, ok: 0, ng: 0, today };
  renderPhrases();
}

function renderFlash() {
  const wrap = document.createElement('div');
  wrap.className = 'ph-flash';

  if (flash.i >= flash.cards.length) {
    const face = document.createElement('div');
    face.className = 'ph-flash-face';
    const t = document.createElement('div');
    t.className = 'ph-flash-meaning';
    t.textContent = T('phFlashDone', String(flash.ok), String(flash.ng));
    face.appendChild(t);
    wrap.appendChild(face);
    const end = document.createElement('button');
    end.className = 'ph-btn primary';
    end.textContent = T('phFlashClose');
    end.addEventListener('click', () => { flash = null; renderPhrases(); });
    wrap.appendChild(end);
    panelPhrases.appendChild(wrap);
    return;
  }

  const c = flash.cards[flash.i];
  const count = document.createElement('div');
  count.className = 'ph-flash-count';
  count.textContent = `${flash.i + 1} / ${flash.cards.length}`;
  wrap.appendChild(count);

  const face = document.createElement('div');
  face.className = 'ph-flash-face';
  const meaning = document.createElement('div');
  meaning.className = 'ph-flash-meaning';
  meaning.textContent = c.meaning;
  face.appendChild(meaning);
  if (flash.open) {
    const ans = document.createElement('div');
    ans.className = 'ph-flash-answer';
    ans.textContent = c.phrase;
    face.appendChild(ans);
  } else {
    const sub = document.createElement('div');
    sub.className = 'ph-flash-sub';
    sub.textContent = T('phFlashSayIt');
    face.appendChild(sub);
  }
  wrap.appendChild(face);

  const btns = document.createElement('div');
  btns.className = 'ph-flash-btns';
  if (!flash.open) {
    const show = document.createElement('button');
    show.className = 'ph-btn primary';
    show.textContent = T('phFlashReveal');
    show.addEventListener('click', () => { flash.open = true; renderPhrases(); });
    btns.appendChild(show);
  } else {
    const answer = async (ok) => {
      const i = enPhrases.findIndex(x => x.id === c.id);
      if (i >= 0) enPhrases[i] = setRecallResult(enPhrases[i], flash.today, ok);
      await HistoryStore.savePhrases(enPhrases);
      if (ok) flash.ok++; else flash.ng++;
      flash.i++; flash.open = false;
      renderPhrases();
    };
    const ok = document.createElement('button');
    ok.className = 'ph-btn ok';
    ok.textContent = T('phFlashOk');
    ok.addEventListener('click', () => answer(true));
    const ng = document.createElement('button');
    ng.className = 'ph-btn ng';
    ng.textContent = T('phFlashNg');
    ng.addEventListener('click', () => answer(false));
    btns.append(ok, ng);
  }
  wrap.appendChild(btns);

  const quit = document.createElement('button');
  quit.className = 'ph-btn plain';
  quit.textContent = T('phFlashQuit');
  quit.addEventListener('click', () => { flash = null; renderPhrases(); });
  wrap.appendChild(quit);

  panelPhrases.appendChild(wrap);
}
