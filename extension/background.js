const PANEL_URL = chrome.runtime.getURL('sidepanel.html');

// 既に開いているウィンドウがあればそれを前面に出す。
// まもるくんは tabs.query（tabs 権限が必要）で探していたが、こちらは
// 作ったウィンドウの id を覚えておく方式にして tabs 権限なしで済ませる
chrome.action.onClicked.addListener(async () => {
  const { hg_window_id } = await chrome.storage.session.get('hg_window_id');
  if (hg_window_id) {
    try {
      await chrome.windows.update(hg_window_id, { focused: true });
      return;
    } catch {
      // ウィンドウが閉じられていた場合はここに来る。作り直す
    }
  }

  const focused = await chrome.windows.getLastFocused();
  const left = Math.max(((focused.left ?? 0) + (focused.width ?? 1200)) - 380 - 10, 0);
  const top  = (focused.top ?? 0) + 10;
  const win = await chrome.windows.create({
    url: PANEL_URL,
    type: 'popup',
    width: 380,
    height: 620,
    left,
    top,
  });
  await chrome.storage.session.set({ hg_window_id: win.id });
});

chrome.windows.onRemoved.addListener(async (windowId) => {
  const { hg_window_id } = await chrome.storage.session.get('hg_window_id');
  if (hg_window_id === windowId) {
    await chrome.storage.session.remove('hg_window_id');
  }
});
