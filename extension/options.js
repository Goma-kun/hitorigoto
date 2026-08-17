// i18n: data-i18n / data-i18n-title を持つ要素へ、ブラウザの言語に応じた文言を流し込む
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

const langSelect        = document.getElementById('lang-select');
const langStatus        = document.getElementById('lang-status');
const engineSelect      = document.getElementById('engine-select');
const engineStatus      = document.getElementById('engine-status');
const engineAvailEl     = document.getElementById('engine-availability');
const apiKeyInput       = document.getElementById('api-key-input');
const saveBtn           = document.getElementById('save-btn');
const testBtn           = document.getElementById('test-btn');
const deleteBtn         = document.getElementById('delete-btn');
const keyStatus         = document.getElementById('key-status');
const keySavedIndicator = document.getElementById('key-saved-indicator');
const tierLabel         = document.getElementById('tier-label');
const exportBtn         = document.getElementById('export-btn');
const importBtn         = document.getElementById('import-btn');
const importFile        = document.getElementById('import-file');
const dataStatus        = document.getElementById('data-status');

function showStatus(msg, type) {
  keyStatus.textContent = msg;
  keyStatus.className   = 'status-' + type;
  keyStatus.style.display = 'block';
}

function hideStatus() {
  keyStatus.style.display = 'none';
}

// Gemini API のエラーを原因ごとに出し分ける
// 403 + "denied access" はキーの誤りではなく、プロジェクトに無料枠が割り当てられていないケース
function geminiErrorText(status, apiMessage) {
  const msg = apiMessage || '';
  if (status === 403 && /denied access/i.test(msg)) return T('errDenied');
  if (status === 401) return T('errKeyInvalid');
  if (status === 400 && /api[ _-]?key/i.test(msg)) return T('errKeyInvalid');
  return msg || T('unknownError');
}

async function loadKey() {
  const { hg_gemini_key } = await chrome.storage.local.get('hg_gemini_key');
  const hasKey = !!hg_gemini_key;

  keySavedIndicator.style.display = hasKey ? '' : 'none';
  apiKeyInput.value = hasKey ? hg_gemini_key : '';
  apiKeyInput.placeholder = hasKey ? T('placeholderSaved') : T('placeholderKey');

  renderTierLabel();
}

// 上部の「現在のAI」。パネル側の selectAiProvider と同じ順で判定して、
// 表示と実際の動きがズレないようにする
async function renderTierLabel() {
  const d = await chrome.storage.local.get(['hg_gemini_key', 'hg_engine']);
  const hasKey = !!d.hg_gemini_key;
  const nanoOk = (await nanoAvailabilityOpt()) === 'available';
  const preferNano = d.hg_engine === 'nano';

  if (nanoOk && (preferNano || !hasKey)) {
    tierLabel.innerHTML = `${T('tierNano')} <span class="tier-badge tier2">${T('badgeNano')}</span>`;
  } else if (hasKey) {
    tierLabel.innerHTML = `${T('tierGemini')} <span class="tier-badge tier2">${T('badgeGemini')}</span>`;
  } else {
    tierLabel.innerHTML = `${T('tierNone')} <span class="tier-badge tier1">${T('badgeNone')}</span>`;
  }
}

saveBtn.addEventListener('click', async () => {
  const key = apiKeyInput.value.trim();
  if (!key) { showStatus(T('enterKey'), 'error'); return; }

  await chrome.storage.local.set({ hg_gemini_key: key });
  showStatus(T('savedOk'), 'ok');
  loadKey();
  setTimeout(hideStatus, 2000);
});

let deleteConfirmTimer = null;
deleteBtn.addEventListener('click', async () => {
  if (deleteBtn.dataset.confirm !== '1') {
    deleteBtn.dataset.confirm = '1';
    deleteBtn.textContent = T('confirmDelete');
    deleteConfirmTimer = setTimeout(() => {
      deleteBtn.dataset.confirm = '';
      deleteBtn.textContent = T('btnDelete');
    }, 3000);
    return;
  }
  clearTimeout(deleteConfirmTimer);
  deleteBtn.dataset.confirm = '';
  deleteBtn.textContent = T('btnDelete');
  await chrome.storage.local.remove('hg_gemini_key');
  apiKeyInput.value = '';
  showStatus(T('keyDeleted'), 'info');
  loadKey();
  setTimeout(hideStatus, 2000);
});

testBtn.addEventListener('click', async () => {
  const key = apiKeyInput.value.trim() || (await chrome.storage.local.get('hg_gemini_key')).hg_gemini_key;
  if (!key) { showStatus(T('enterOrSaveFirst'), 'error'); return; }

  showStatus(T('testing'), 'testing');
  testBtn.disabled = true;

  try {
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent?key=${key}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          contents: [{ role: 'user', parts: [{ text: 'ping' }] }],
          tools: []
        })
      }
    );
    const data = await res.json();
    if (res.ok && data.candidates) {
      showStatus(T('testOk'), 'ok');
    } else {
      showStatus(T('errorPrefix') + geminiErrorText(res.status, data?.error?.message), 'error');
    }
  } catch (err) {
    showStatus(T('networkError') + err.message, 'error');
  } finally {
    testBtn.disabled = false;
  }
});

// ── AIエンジン（添削に使うAI） ──
// Chrome 内蔵 AI（Prompt API / Gemini Nano）の利用可否は端末ごとに違うので、ここで見せる
async function nanoAvailabilityOpt() {
  if (typeof LanguageModel === 'undefined') return 'unavailable';
  try { return await LanguageModel.availability(); } catch { return 'unavailable'; }
}

function showEngineStatus(msg, type) {
  engineStatus.textContent = msg;
  engineStatus.className   = 'status-' + type;
  engineStatus.style.display = 'block';
}

async function loadEngine() {
  const { hg_engine } = await chrome.storage.local.get('hg_engine');
  engineSelect.value = hg_engine === 'nano' ? 'nano' : 'auto';

  const s = await nanoAvailabilityOpt();
  engineAvailEl.textContent =
    s === 'available' ? T('engineNanoReady')
    : (s === 'downloadable' || s === 'downloading') ? T('engineNanoDownload')
    : T('engineNanoNo');

  // モデルが未DLの端末では、DLを始めるボタンを出す（create はユーザー操作が必須）
  if (s === 'downloadable' || s === 'downloading') {
    const btn = document.createElement('button');
    btn.className = 'btn btn-test';
    btn.style.marginTop = '10px';
    btn.textContent = T('btnEnableNano');
    btn.addEventListener('click', () => startNanoDownload());
    engineAvailEl.insertAdjacentElement('afterend', btn);
  }
}

engineSelect.addEventListener('change', async () => {
  await chrome.storage.local.set({ hg_engine: engineSelect.value });
  showEngineStatus(T('engineSetTo'), 'ok');
  setTimeout(() => { engineStatus.style.display = 'none'; }, 2000);
  renderTierLabel();

  // 端末内 AI を選んでモデルが未DLなら、この操作（クリック）を起点にDLを始める。
  // モデルDLを伴う create() はユーザー操作が必須のため、裏で勝手には始められない
  if (engineSelect.value === 'nano') {
    const s = await nanoAvailabilityOpt();
    if (s === 'downloadable' || s === 'downloading') startNanoDownload();
  }
});

let nanoDlRunning = false;
async function startNanoDownload() {
  if (nanoDlRunning || typeof LanguageModel === 'undefined') return;
  nanoDlRunning = true;
  showEngineStatus(T('engineDownloading') + ' 0%', 'testing');
  try {
    const session = await LanguageModel.create({
      monitor(m) {
        m.addEventListener('downloadprogress', (e) => {
          showEngineStatus(T('engineDownloading') + ' ' + Math.round(e.loaded * 100) + '%', 'testing');
        });
      },
    });
    session.destroy();
    showEngineStatus(T('engineDownloadDone'), 'ok');
    engineAvailEl.textContent = T('engineNanoReady');
    renderTierLabel();
  } catch (err) {
    // 進まない・失敗するケースの実例あり（Chrome の再起動で直る）。案内込みで出す
    showEngineStatus(T('engineDownloadFail') + (err.message || err), 'error');
  } finally {
    nanoDlRunning = false;
  }
}

// ── 聞き取る英語 ──
async function loadLang() {
  const { hg_lang } = await chrome.storage.local.get('hg_lang');
  langSelect.value = hg_lang === 'en-GB' ? 'en-GB' : 'en-US';
}

langSelect.addEventListener('change', async () => {
  await chrome.storage.local.set({ hg_lang: langSelect.value });
  const label = langSelect.options[langSelect.selectedIndex].textContent;
  langStatus.textContent = T('langSetTo', label);
  langStatus.className = 'status-ok';
  langStatus.style.display = 'block';
  setTimeout(() => { langStatus.style.display = 'none'; }, 2000);
});

// ── 記録の書き出し・読み込み ──
function showDataStatus(msg, type) {
  dataStatus.textContent = msg;
  dataStatus.className   = 'status-' + type;
  dataStatus.style.display = 'block';
}

exportBtn.addEventListener('click', async () => {
  const json = await HistoryStore.exportEnglishJson();
  const stamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
  const blob = new Blob([json], { type: 'application/json' });
  const url  = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `hitorigoto-history-${stamp}.json`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  showDataStatus(T('exportDone'), 'ok');
  setTimeout(() => { dataStatus.style.display = 'none'; }, 2500);
});

importBtn.addEventListener('click', () => importFile.click());

importFile.addEventListener('change', async () => {
  const file = importFile.files && importFile.files[0];
  importFile.value = '';   // 同じファイルをもう一度選んでも change が発火するように
  if (!file) return;

  try {
    const text = await file.text();
    const result = await HistoryStore.importEnglishJson(text);
    showDataStatus(T('importDone', String(result.sessions)), 'ok');
  } catch {
    showDataStatus(T('importError'), 'error');
  }
});

document.addEventListener('DOMContentLoaded', () => { applyI18n(); loadKey(); loadLang(); loadEngine(); });
