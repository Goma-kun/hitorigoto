// ============================================================
// 録音層。マイクの生音を MediaRecorder で溜め、停止時に Blob として返す。
// 音声認識層（speech.js）とは独立に動く。Web Speech は画面に流す途中経過のため、
// こちらは Gemini に渡す一次資料のため、という役割分担
// ============================================================
const AudioCapture = {
  supported() {
    return !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia && window.MediaRecorder);
  },

  // 使い方: const rec = AudioCapture.create(); await rec.start(); … const blob = await rec.stop();
  // start が getUserMedia で拒否されたら例外。呼び出し側はテキストだけで続行する
  create() {
    let stream   = null;
    let recorder = null;
    let chunks   = [];
    let gen      = 0;   // start と stop の追い越し対策（getUserMedia 待ちの間に stop された場合）

    // Gemini が受け付ける形を優先。Chrome は webm/opus を持っている
    const MIME_CANDIDATES = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus'];

    function release() {
      if (stream) stream.getTracks().forEach(t => t.stop());
      stream = null; recorder = null; chunks = [];
    }

    return {
      get active() { return !!recorder && recorder.state === 'recording'; },

      async start() {
        if (recorder) return true;
        const myGen = ++gen;
        const s = await navigator.mediaDevices.getUserMedia({
          audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true },
        });
        if (myGen !== gen) {
          // 待っている間に stop された。開いたマイクは閉じて何もしない
          s.getTracks().forEach(t => t.stop());
          return false;
        }
        stream = s;
        const mimeType = MIME_CANDIDATES.find(m => MediaRecorder.isTypeSupported(m));
        recorder = new MediaRecorder(stream, {
          ...(mimeType ? { mimeType } : {}),
          audioBitsPerSecond: 32000,   // 声の書き起こしには十分で、7 分でも 2MB 程度に収まる
        });
        chunks = [];
        recorder.ondataavailable = (e) => { if (e.data && e.data.size > 0) chunks.push(e.data); };
        recorder.start(1000);          // 1 秒ごとに溜める（長時間でもメモリを一気に食わない）
        return true;
      },

      // 録音を止めて Blob を返す。録音していなければ null
      stop() {
        gen++;
        if (!recorder) { release(); return Promise.resolve(null); }
        const rec = recorder;
        return new Promise((resolve) => {
          rec.onstop = () => {
            const blob = chunks.length ? new Blob(chunks, { type: rec.mimeType || 'audio/webm' }) : null;
            release();
            resolve(blob);
          };
          try { rec.stop(); } catch { release(); resolve(null); }
        });
      },
    };
  },
};
