(function () {
  "use strict";

  const MAX_SIDE = 1600; // 処理解像度の上限(px)

  const $ = (id) => document.getElementById(id);
  const canvas = $("canvas");
  const ctx = canvas.getContext("2d");
  const ui = {
    file: $("file-input"),
    drop: $("drop-zone"),
    sample: $("sample-btn"),
    sensitivity: $("sensitivity"),
    minLength: $("min-length"),
    elongation: $("elongation"),
    connect: $("connect"),
    realWidth: $("real-width"),
    download: $("download-btn"),
    placeholder: $("placeholder"),
    summary: $("summary"),
    table: $("result-table"),
  };

  const state = { source: null, result: null, view: "result", selected: 0, mode: "ai", prob: null, runId: 0 };

  // ---- AIモデル(U-Net, ONNX)----
  const MODEL_URL = "model/crack-unet.onnx";
  const AI_MAX_SIDE = 1024; // AI推論の解像度上限(速度とのバランス)
  const TILE = 512, OVERLAP = 48;
  let sessionPromise = null;

  function getSession() {
    if (!sessionPromise) {
      if (typeof ort === "undefined") return Promise.reject(new Error("onnxruntime-web を読み込めませんでした"));
      ort.env.wasm.numThreads = self.crossOriginIsolated ? Math.min(4, navigator.hardwareConcurrency || 1) : 1;
      sessionPromise = ort.InferenceSession.create(MODEL_URL, { executionProviders: ["wasm"] });
      sessionPromise.catch(() => { sessionPromise = null; });
    }
    return sessionPromise;
  }

  function tileStarts(len) {
    if (len <= TILE) return [0];
    const out = [];
    for (let x = 0; ; x += TILE - OVERLAP * 2) {
      if (x + TILE >= len) { out.push(len - TILE); break; }
      out.push(x);
    }
    return out;
  }

  // 画像を縮小 → タイル分割して推論 → 元の処理解像度へ拡大した確率マップを返す
  async function predict(source, onProgress) {
    const session = await getSession();
    const { width: W, height: H } = source.imageData;
    const s = Math.min(1, AI_MAX_SIDE / Math.max(W, H));
    const w = Math.round(W * s), h = Math.round(H * s);
    const small = document.createElement("canvas");
    small.width = w; small.height = h;
    const sctx = small.getContext("2d");
    sctx.drawImage(source.canvas, 0, 0, w, h);
    const px = sctx.getImageData(0, 0, w, h).data;

    const acc = new Float32Array(w * h), cnt = new Float32Array(w * h);
    const xs = tileStarts(w), ys = tileStarts(h);
    let done = 0;
    for (const ty of ys) {
      for (const tx of xs) {
        const tw = Math.min(TILE, w), th = Math.min(TILE, h);
        const pw = Math.ceil(tw / 16) * 16, ph = Math.ceil(th / 16) * 16;
        const input = new Float32Array(3 * pw * ph);
        const plane = pw * ph;
        for (let y = 0; y < ph; y++) {
          const sy = ty + Math.min(y, th - 1);
          for (let x = 0; x < pw; x++) {
            const p = (sy * w + tx + Math.min(x, tw - 1)) * 4, o = y * pw + x;
            input[o] = px[p] / 255; input[plane + o] = px[p + 1] / 255; input[2 * plane + o] = px[p + 2] / 255;
          }
        }
        const out = await session.run({ image: new ort.Tensor("float32", input, [1, 3, ph, pw]) });
        const prob = out.prob.data;
        for (let y = 0; y < th; y++) {
          for (let x = 0; x < tw; x++) {
            const i = (ty + y) * w + tx + x;
            acc[i] += prob[y * pw + x]; cnt[i] += 1;
          }
        }
        onProgress && onProgress(++done / (xs.length * ys.length));
      }
    }
    for (let i = 0; i < acc.length; i++) acc[i] /= cnt[i];
    if (w === W && h === H) return acc;

    // 双線形補間で処理解像度へ戻す
    const full = new Float32Array(W * H);
    const fx = (w - 1) / Math.max(1, W - 1), fy = (h - 1) / Math.max(1, H - 1);
    for (let y = 0; y < H; y++) {
      const gy = y * fy, y0 = Math.floor(gy), y1 = Math.min(h - 1, y0 + 1), ay = gy - y0;
      for (let x = 0; x < W; x++) {
        const gx = x * fx, x0 = Math.floor(gx), x1 = Math.min(w - 1, x0 + 1), ax = gx - x0;
        full[y * W + x] =
          (acc[y0 * w + x0] * (1 - ax) + acc[y0 * w + x1] * ax) * (1 - ay) +
          (acc[y1 * w + x0] * (1 - ax) + acc[y1 * w + x1] * ax) * ay;
      }
    }
    return full;
  }

  const busy = $("busy"), busyText = $("busy-text"), modeNote = $("mode-note");
  const MODE_NOTES = {
    ai: "ひび割れ写真で学習したAIモデルで判定します。初回はモデルの読み込みに数秒かかります。",
    classic: "周囲より暗い細い線を画像処理で抽出します。高速ですが、薄いひびの見逃しや模様の誤検出が多めです。",
  };
  function setMode(mode) {
    state.mode = mode;
    document.querySelectorAll(".mode-tabs .tab").forEach((t) => t.classList.toggle("active", t.dataset.mode === mode));
    modeNote.textContent = MODE_NOTES[mode];
    runDetection();
  }
  document.querySelectorAll(".mode-tabs .tab").forEach((t) => t.addEventListener("click", () => setMode(t.dataset.mode)));
  modeNote.textContent = MODE_NOTES.ai;

  // ---- 設定の初期化 ----
  const D = CrackDetector.DEFAULTS;
  ui.sensitivity.value = D.sensitivity;
  ui.minLength.value = D.minLengthPct;
  ui.elongation.value = D.minElongation;
  ui.connect.checked = D.connect;

  function updateLabels() {
    $("sensitivity-value").textContent = ui.sensitivity.value;
    $("min-length-value").textContent = `画像対角の ${ui.minLength.value}%`;
    $("elongation-value").textContent = `長さ ÷ 幅 ≧ ${ui.elongation.value}`;
  }
  updateLabels();

  // ---- 画像の読み込み ----
  function loadFile(file) {
    if (!file || !file.type.startsWith("image/")) return;
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => { URL.revokeObjectURL(url); setSource(img); };
    img.onerror = () => alert("画像を読み込めませんでした");
    img.src = url;
  }

  function setSource(img) {
    const scale = Math.min(1, MAX_SIDE / Math.max(img.naturalWidth || img.width, img.naturalHeight || img.height));
    const w = Math.round((img.naturalWidth || img.width) * scale);
    const h = Math.round((img.naturalHeight || img.height) * scale);
    const off = document.createElement("canvas");
    off.width = w; off.height = h;
    off.getContext("2d").drawImage(img, 0, 0, w, h);
    state.source = { canvas: off, imageData: off.getContext("2d").getImageData(0, 0, w, h) };
    state.prob = null;
    canvas.width = w; canvas.height = h;
    ui.placeholder.hidden = true;
    runDetection();
  }

  ui.file.addEventListener("change", (e) => loadFile(e.target.files[0]));
  ["dragenter", "dragover"].forEach((t) => ui.drop.addEventListener(t, (e) => { e.preventDefault(); ui.drop.classList.add("dragover"); }));
  ["dragleave", "drop"].forEach((t) => ui.drop.addEventListener(t, (e) => { e.preventDefault(); ui.drop.classList.remove("dragover"); }));
  ui.drop.addEventListener("drop", (e) => loadFile(e.dataTransfer.files[0]));
  ui.sample.addEventListener("click", () => setSource(makeSample()));

  // ---- 検出 ----
  let timer = null;
  function scheduleDetection() {
    updateLabels();
    clearTimeout(timer);
    timer = setTimeout(runDetection, 150);
  }
  [ui.sensitivity, ui.minLength, ui.elongation, ui.connect].forEach((el) => el.addEventListener("input", scheduleDetection));
  ui.realWidth.addEventListener("input", () => { if (state.result) { render(); renderReport(); } });

  async function runDetection() {
    if (!state.source) return;
    const id = ++state.runId;
    const source = state.source;
    let prob = null;
    if (state.mode === "ai") {
      if (!state.prob) {
        busy.hidden = false;
        busyText.textContent = "AIモデルを準備中…";
        try {
          const p = await predict(source, (r) => { busyText.textContent = `AIで解析中… ${Math.round(r * 100)}%`; });
          if (source === state.source) state.prob = p;
        } catch (e) {
          console.error(e);
          busy.hidden = true;
          modeNote.textContent = "AIモデルを読み込めなかったため、画像処理で検出しました(index.html を直接開いた場合は、README の手順でローカルサーバーから開いてください)。";
          if (id === state.runId) { state.mode = "classic"; document.querySelectorAll(".mode-tabs .tab").forEach((t) => t.classList.toggle("active", t.dataset.mode === "classic")); }
        }
        busy.hidden = true;
      }
      if (id !== state.runId || source !== state.source) return; // 新しい処理が始まっていたら破棄
      prob = state.mode === "ai" ? state.prob : null;
    }
    state.result = CrackDetector.detect(source.imageData, {
      sensitivity: +ui.sensitivity.value,
      minLengthPct: +ui.minLength.value,
      minElongation: +ui.elongation.value,
      connect: ui.connect.checked,
    }, prob);
    state.selected = 0;
    ui.download.disabled = false;
    render();
    renderReport();
  }

  // 1画素あたりの mm(実寸未入力なら null)
  function mmPerPx() {
    const cm = parseFloat(ui.realWidth.value);
    if (!state.result || !(cm > 0)) return null;
    return (cm * 10) / state.result.width;
  }

  function crackInfo(c) {
    const s = mmPerPx();
    const fmtLen = (px) => s ? (px * s >= 100 ? `${(px * s / 10).toFixed(1)} cm` : `${(px * s).toFixed(0)} mm`) : `${px.toFixed(0)} px`;
    const fmtW = (px) => s ? `${(px * s).toFixed(2)} mm` : `${px.toFixed(1)} px`;
    const cls = CrackDetector.classify(s ? c.maxWidthPx * s : null);
    return { length: fmtLen(c.lengthPx), meanW: fmtW(c.meanWidthPx), maxW: fmtW(c.maxWidthPx), cls };
  }

  // ---- 描画 ----
  function hexToRgb(hex) {
    const n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }

  function render() {
    const r = state.result;
    if (!r) return;
    const { width: w, height: h } = r;

    if (state.view === "mask") {
      const img = ctx.createImageData(w, h);
      for (let i = 0, p = 0; i < r.rawMask.length; i++, p += 4) {
        const v = r.labels[i] ? 255 : r.rawMask[i] ? 90 : 0;
        img.data[p] = v; img.data[p + 1] = r.labels[i] ? 60 : v; img.data[p + 2] = r.labels[i] ? 60 : v; img.data[p + 3] = 255;
      }
      ctx.putImageData(img, 0, 0);
      return;
    }

    ctx.drawImage(state.source.canvas, 0, 0);
    if (state.view === "original") return;

    // ひび画素を危険度色で塗る
    const colors = r.cracks.map((c) => hexToRgb(crackInfo(c).cls.color));
    const img = ctx.getImageData(0, 0, w, h);
    const d = img.data;
    for (let i = 0, p = 0; i < r.labels.length; i++, p += 4) {
      // 背景は少し暗くしてひびを目立たせる
      const n = r.labels[i];
      if (n) {
        const [cr, cg, cb] = colors[n - 1];
        d[p] = cr; d[p + 1] = cg; d[p + 2] = cb;
      } else {
        d[p] *= 0.75; d[p + 1] *= 0.75; d[p + 2] *= 0.75;
      }
    }
    ctx.putImageData(img, 0, 0);

    // 枠と番号
    const lw = Math.max(2, Math.round(w / 500));
    ctx.font = `bold ${Math.max(14, Math.round(w / 55))}px system-ui, sans-serif`;
    ctx.textBaseline = "top";
    r.cracks.forEach((c, idx) => {
      const { cls } = crackInfo(c);
      const pad = lw * 3;
      const sel = state.selected === c.no;
      ctx.lineWidth = sel ? lw * 2 : lw;
      ctx.strokeStyle = cls.color;
      ctx.setLineDash(sel ? [] : [lw * 4, lw * 3]);
      ctx.strokeRect(c.bbox.x - pad, c.bbox.y - pad, c.bbox.w + pad * 2, c.bbox.h + pad * 2);
      ctx.setLineDash([]);
      const label = `#${c.no}`;
      const tw = ctx.measureText(label).width + 10;
      const th = parseInt(ctx.font.match(/\d+/)[0], 10) + 6;
      const lx = Math.min(Math.max(0, c.bbox.x - pad), w - tw);
      const ly = c.bbox.y - pad - th >= 0 ? c.bbox.y - pad - th : c.bbox.y + c.bbox.h + pad;
      ctx.fillStyle = cls.color;
      ctx.fillRect(lx, ly, tw, th);
      ctx.fillStyle = "#fff";
      ctx.fillText(label, lx + 5, ly + 3);
    });
  }

  function renderReport() {
    const r = state.result;
    const s = mmPerPx();
    const n = r.cracks.length;
    const totalPx = r.cracks.reduce((a, c) => a + c.lengthPx, 0);
    const maxW = n ? Math.max(...r.cracks.map((c) => c.maxWidthPx)) : 0;
    const worst = n ? CrackDetector.classify(s ? maxW * s : null) : null;
    const fmtTotal = s ? (totalPx * s >= 100 ? `${(totalPx * s / 10).toFixed(1)} cm` : `${(totalPx * s).toFixed(0)} mm`) : `${totalPx.toFixed(0)} px`;

    ui.summary.hidden = false;
    ui.summary.innerHTML = `
      <div class="stat"><div class="k">検出したひび</div><div class="v">${n} 本</div></div>
      <div class="stat"><div class="k">総延長</div><div class="v">${n ? fmtTotal : "—"}</div></div>
      <div class="stat"><div class="k">最大幅</div><div class="v">${n ? (s ? (maxW * s).toFixed(2) + " mm" : maxW.toFixed(1) + " px") : "—"}</div></div>
      <div class="stat"><div class="k">総合判定</div><div class="v">${n ? (s ? `<span class="badge" style="background:${worst.color}">${worst.label}</span>` : '<small class="note">実寸を入力すると判定します</small>') : "ひびなし"}</div></div>`;

    const tbody = ui.table.querySelector("tbody");
    tbody.innerHTML = "";
    ui.table.hidden = n === 0;
    r.cracks.forEach((c) => {
      const info = crackInfo(c);
      const tr = document.createElement("tr");
      if (state.selected === c.no) tr.classList.add("selected");
      tr.innerHTML = `<td>#${c.no}</td><td>${info.length}</td><td>${info.meanW}</td><td>${info.maxW}</td>
        <td><span class="badge" style="background:${info.cls.color}">${s ? info.cls.label : "—"}</span></td>`;
      tr.addEventListener("click", () => {
        state.selected = state.selected === c.no ? 0 : c.no;
        setView("result");
        renderReport();
      });
      tbody.appendChild(tr);
    });
  }

  function setView(v) {
    state.view = v;
    document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("active", t.dataset.view === v));
    render();
  }
  document.querySelectorAll(".tab").forEach((t) => t.addEventListener("click", () => setView(t.dataset.view)));

  ui.download.addEventListener("click", () => {
    const prev = state.view;
    if (prev !== "result") setView("result");
    const a = document.createElement("a");
    a.href = canvas.toDataURL("image/png");
    a.download = "crack-detection.png";
    a.click();
    if (prev !== "result") setView(prev);
  });

  // ---- サンプル画像(コンクリート壁を模した合成画像) ----
  function makeSample() {
    const w = 1200, h = 800;
    const c = document.createElement("canvas");
    c.width = w; c.height = h;
    const g = c.getContext("2d");
    let seed = 7;
    const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);

    // 下地(照明ムラのあるグラデーション + ざらつき)
    const grad = g.createLinearGradient(0, 0, w, h);
    grad.addColorStop(0, "#c9c6bf"); grad.addColorStop(1, "#a9a69f");
    g.fillStyle = grad; g.fillRect(0, 0, w, h);
    const img = g.getImageData(0, 0, w, h);
    for (let p = 0; p < img.data.length; p += 4) {
      const n = (rnd() - 0.5) * 28;
      img.data[p] += n; img.data[p + 1] += n; img.data[p + 2] += n;
    }
    g.putImageData(img, 0, 0);

    // シミ(誤検出させたくない丸い暗部)
    g.fillStyle = "rgba(90,85,75,0.35)";
    g.beginPath(); g.ellipse(950, 600, 70, 45, 0.4, 0, Math.PI * 2); g.fill();
    g.beginPath(); g.arc(250, 650, 14, 0, Math.PI * 2); g.fill();

    // ひび(ランダムウォークの折れ線)
    function crack(x, y, angle, steps, width) {
      g.strokeStyle = "rgba(45,40,35,0.9)";
      g.lineCap = "round";
      for (let i = 0; i < steps; i++) {
        angle += (rnd() - 0.5) * 0.6;
        const nx = x + Math.cos(angle) * 6, ny = y + Math.sin(angle) * 6;
        g.lineWidth = Math.max(1, width * (1 - i / steps * 0.6));
        g.beginPath(); g.moveTo(x, y); g.lineTo(nx, ny); g.stroke();
        x = nx; y = ny;
        if (rnd() < 0.015 && width > 2) crack(x, y, angle + (rnd() - 0.5) * 1.6, steps / 3, width * 0.5);
      }
    }
    crack(120, 120, 0.55, 150, 6);
    crack(700, 80, 1.9, 90, 2.5);
    return c;
  }
})();
