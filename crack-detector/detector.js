/**
 * ひび割れ検出エンジン(依存ライブラリなし)
 *
 * 処理の流れ:
 *  1. グレースケール化 + 軽い平滑化(ノイズ除去)
 *  2. 局所平均との差分で「周囲より暗い細い部分」を抽出(照明ムラに強い)
 *  3. 二値化 → クロージングで途切れたひびをつなぐ
 *  4. 連結成分ごとに面積・大きさで足切り
 *  5. 細線化(Zhang-Suen)で骨格を求め、長さを計測
 *  6. 距離変換で骨格上の幅を計測
 *  7. 「細長さ(長さ/幅)」で汚れ・シミなどの塊状のものを除外
 */
(function (global) {
  "use strict";

  const DEFAULTS = {
    sensitivity: 50,   // 0-100 大きいほど薄いひびも拾う
    minLengthPct: 3,   // 画像対角線に対する最小長さ(%)
    minElongation: 6,  // 長さ/平均幅 の下限
    connect: true,     // 途切れたひびをつなぐ
  };

  function toGray(imageData) {
    const { data, width, height } = imageData;
    const g = new Float32Array(width * height);
    for (let i = 0, p = 0; i < g.length; i++, p += 4) {
      g[i] = 0.299 * data[p] + 0.587 * data[p + 1] + 0.114 * data[p + 2];
    }
    return g;
  }

  // 積分画像を使った箱型平均(半径 r)
  function boxMean(src, w, h, r) {
    const W = w + 1;
    const integ = new Float64Array(W * (h + 1));
    for (let y = 0; y < h; y++) {
      let row = 0;
      for (let x = 0; x < w; x++) {
        row += src[y * w + x];
        integ[(y + 1) * W + x + 1] = integ[y * W + x + 1] + row;
      }
    }
    const out = new Float32Array(w * h);
    for (let y = 0; y < h; y++) {
      const y0 = Math.max(0, y - r), y1 = Math.min(h, y + r + 1);
      for (let x = 0; x < w; x++) {
        const x0 = Math.max(0, x - r), x1 = Math.min(w, x + r + 1);
        const s = integ[y1 * W + x1] - integ[y0 * W + x1] - integ[y1 * W + x0] + integ[y0 * W + x0];
        out[y * w + x] = s / ((x1 - x0) * (y1 - y0));
      }
    }
    return out;
  }

  function dilate(mask, w, h) {
    const out = new Uint8Array(mask.length);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let v = 0;
        for (let dy = -1; dy <= 1 && !v; dy++) {
          const yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (let dx = -1; dx <= 1; dx++) {
            const xx = x + dx;
            if (xx >= 0 && xx < w && mask[yy * w + xx]) { v = 1; break; }
          }
        }
        out[y * w + x] = v;
      }
    }
    return out;
  }

  function erode(mask, w, h) {
    const out = new Uint8Array(mask.length);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let v = 1;
        for (let dy = -1; dy <= 1 && v; dy++) {
          const yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (let dx = -1; dx <= 1; dx++) {
            const xx = x + dx;
            if (xx >= 0 && xx < w && !mask[yy * w + xx]) { v = 0; break; }
          }
        }
        out[y * w + x] = v;
      }
    }
    return out;
  }

  // 8近傍の連結成分ラベリング
  function label(mask, w, h) {
    const labels = new Int32Array(w * h);
    const comps = [];
    const stack = new Int32Array(w * h);
    let next = 0;
    for (let i = 0; i < mask.length; i++) {
      if (!mask[i] || labels[i]) continue;
      next++;
      let sp = 0, count = 0;
      let minX = w, minY = h, maxX = 0, maxY = 0;
      stack[sp++] = i;
      labels[i] = next;
      while (sp) {
        const p = stack[--sp];
        const x = p % w, y = (p - x) / w;
        count++;
        if (x < minX) minX = x; if (x > maxX) maxX = x;
        if (y < minY) minY = y; if (y > maxY) maxY = y;
        for (let dy = -1; dy <= 1; dy++) {
          const yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (let dx = -1; dx <= 1; dx++) {
            const xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            const q = yy * w + xx;
            if (mask[q] && !labels[q]) { labels[q] = next; stack[sp++] = q; }
          }
        }
      }
      comps.push({ id: next, area: count, minX, minY, maxX, maxY });
    }
    return { labels, comps };
  }

  // Zhang-Suen 細線化(前景画素リストのみを走査)
  function thin(mask, w, h) {
    const m = new Uint8Array(mask);
    let pts = [];
    for (let i = 0; i < m.length; i++) {
      if (m[i]) {
        const x = i % w, y = (i - x) / w;
        if (x > 0 && y > 0 && x < w - 1 && y < h - 1) pts.push(i); else m[i] = 0;
      }
    }
    let changed = true;
    const del = [];
    while (changed) {
      changed = false;
      for (let step = 0; step < 2; step++) {
        del.length = 0;
        for (const i of pts) {
          if (!m[i]) continue;
          const p2 = m[i - w], p3 = m[i - w + 1], p4 = m[i + 1], p5 = m[i + w + 1];
          const p6 = m[i + w], p7 = m[i + w - 1], p8 = m[i - 1], p9 = m[i - w - 1];
          const B = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9;
          if (B < 2 || B > 6) continue;
          const A = (!p2 && p3) + (!p3 && p4) + (!p4 && p5) + (!p5 && p6) +
                    (!p6 && p7) + (!p7 && p8) + (!p8 && p9) + (!p9 && p2);
          if (A !== 1) continue;
          if (step === 0) {
            if (p2 * p4 * p6 || p4 * p6 * p8) continue;
          } else {
            if (p2 * p4 * p8 || p2 * p6 * p8) continue;
          }
          del.push(i);
        }
        if (del.length) {
          changed = true;
          for (const i of del) m[i] = 0;
        }
      }
      pts = pts.filter((i) => m[i]);
    }
    return m;
  }

  // 3-4 チャンファー距離変換(背景までの距離、単位: 画素)
  function distance(mask, w, h) {
    const INF = 1e9;
    const d = new Float32Array(w * h);
    for (let i = 0; i < d.length; i++) d[i] = mask[i] ? INF : 0;
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const i = y * w + x;
        if (!d[i]) continue;
        let v = d[i];
        if (x > 0) v = Math.min(v, d[i - 1] + 3); else v = Math.min(v, 3);
        if (y > 0) {
          v = Math.min(v, d[i - w] + 3);
          if (x > 0) v = Math.min(v, d[i - w - 1] + 4);
          if (x < w - 1) v = Math.min(v, d[i - w + 1] + 4);
        } else v = Math.min(v, 3);
        d[i] = v;
      }
    }
    for (let y = h - 1; y >= 0; y--) {
      for (let x = w - 1; x >= 0; x--) {
        const i = y * w + x;
        if (!d[i]) continue;
        let v = d[i];
        if (x < w - 1) v = Math.min(v, d[i + 1] + 3); else v = Math.min(v, 3);
        if (y < h - 1) {
          v = Math.min(v, d[i + w] + 3);
          if (x < w - 1) v = Math.min(v, d[i + w + 1] + 4);
          if (x > 0) v = Math.min(v, d[i + w - 1] + 4);
        } else v = Math.min(v, 3);
        d[i] = v;
      }
    }
    for (let i = 0; i < d.length; i++) d[i] /= 3;
    return d;
  }

  // 骨格の長さ(斜めは√2として数える)
  function skeletonLength(skel, w, pixels) {
    let len = 0;
    for (const i of pixels) {
      // 右・下・右下・左下 方向の接続のみ数えて二重カウントを防ぐ
      if (skel[i + 1]) len += 1;
      if (skel[i + w]) len += 1;
      if (skel[i + w + 1] && !skel[i + 1] && !skel[i + w]) len += Math.SQRT2;
      if (skel[i + w - 1] && !skel[i - 1] && !skel[i + w]) len += Math.SQRT2;
    }
    return Math.max(len, pixels.length ? 1 : 0);
  }

  /**
   * ひび割れ検出
   * @param imageData 入力画像
   * @param options   設定
   * @param prob      AIモデルのひび確率マップ(0〜1, 省略時は画像処理で候補を作る)
   */
  function detect(imageData, options, prob) {
    const opt = Object.assign({}, DEFAULTS, options || {});
    const { width: w, height: h } = imageData;
    const diag = Math.hypot(w, h);

    // 1. グレースケール + 平滑化
    const gray = boxMean(toGray(imageData), w, h, 1);

    // 2. 局所平均との差(暗いほど正)
    const r = Math.max(8, Math.round(Math.max(w, h) / 60));
    const mean = boxMean(gray, w, h, r);
    const diff = new Float32Array(w * h);
    let sum = 0, sum2 = 0;
    for (let i = 0; i < diff.length; i++) {
      const v = mean[i] - gray[i];
      diff[i] = v;
      sum += v; sum2 += v * v;
    }
    const sd = Math.sqrt(Math.max(1e-6, sum2 / diff.length - (sum / diff.length) ** 2));

    // 3. 二値化
    let mask = new Uint8Array(w * h);
    let thr;
    if (prob) {
      // AI: ヒステリシス二値化(確実な画素を起点に、やや弱い画素までつなげる)
      thr = 0.8 - (opt.sensitivity / 100) * 0.6;   // 感度50で0.5
      const weak = thr * 0.6;
      const stack = [];
      for (let i = 0; i < mask.length; i++) if (prob[i] > thr) { mask[i] = 1; stack.push(i); }
      while (stack.length) {
        const p = stack.pop();
        const x = p % w, y = (p - x) / w;
        for (let dy = -1; dy <= 1; dy++) {
          const yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (let dx = -1; dx <= 1; dx++) {
            const xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            const q = yy * w + xx;
            if (!mask[q] && prob[q] > weak) { mask[q] = 1; stack.push(q); }
          }
        }
      }
    } else {
      // 画像処理: 表面のざらつき(標準偏差)を基準に閾値を決める
      const k = 4.5 - (opt.sensitivity / 100) * 3.5;  // 4.5σ 〜 1.0σ
      thr = Math.max(4, k * sd);
      for (let i = 0; i < mask.length; i++) mask[i] = diff[i] > thr ? 1 : 0;
    }
    if (opt.connect) mask = erode(dilate(mask, w, h), w, h);

    return analyze(mask, diff, gray, w, h, opt, diag, thr);
  }

  function analyze(mask, diff, gray, w, h, opt, diag, thr) {
    // 4. 連結成分と粗い足切り
    const minLen = (opt.minLengthPct / 100) * diag;
    const { labels, comps } = label(mask, w, h);
    const keep = new Uint8Array(comps.length + 1);
    const cand = new Uint8Array(w * h);
    for (const c of comps) {
      const span = Math.hypot(c.maxX - c.minX + 1, c.maxY - c.minY + 1);
      if (c.area >= 10 && span >= minLen) keep[c.id] = 1;
    }
    for (let i = 0; i < cand.length; i++) if (keep[labels[i]]) cand[i] = 1;

    // 5-6. 細線化と距離変換
    const skel = thin(cand, w, h);
    const dist = distance(cand, w, h);

    const skelPix = new Map();
    for (let i = 0; i < skel.length; i++) {
      if (!skel[i]) continue;
      const id = labels[i];
      if (!skelPix.has(id)) skelPix.set(id, []);
      skelPix.get(id).push(i);
    }

    // 幅は「暗さ」から測る: 各ひび領域で、中心の暗さの半分以上暗い画素(半値幅)を本体とみなし、
    // DeepCrack の正解幅で校正した係数を掛ける(AIの出力領域は細いひびでは実際より太くなるため)
    const rW = Math.max(15, Math.round(Math.max(w, h) / 30));
    const meanW = boxMean(gray, w, h, rW);
    const depth = new Float32Array(w * h);
    for (let i = 0; i < depth.length; i++) depth[i] = meanW[i] - gray[i];
    const byComp = new Map();
    for (let i = 0; i < cand.length; i++) {
      if (!cand[i]) continue;
      const id = labels[i];
      if (!byComp.has(id)) byComp.set(id, []);
      byComp.get(id).push(depth[i]);
    }
    const coreThr = new Map();
    for (const [id, v] of byComp) {
      v.sort((a, b) => a - b);
      coreThr.set(id, Math.max(3, 0.5 * v[Math.floor(v.length * 0.9)]));
    }
    const core = new Uint8Array(w * h);
    for (let i = 0; i < core.length; i++) if (cand[i] && depth[i] >= coreThr.get(labels[i])) core[i] = 1;
    const coreSkel = thin(core, w, h);
    const coreDist = distance(core, w, h);
    const coreArea = new Map(), coreWidths = new Map();
    for (let i = 0; i < core.length; i++) {
      if (!core[i]) continue;
      const id = labels[i];
      coreArea.set(id, (coreArea.get(id) || 0) + 1);
      if (coreSkel[i]) {
        if (!coreWidths.has(id)) coreWidths.set(id, []);
        coreWidths.get(id).push(Math.max(1, 2 * coreDist[i] - 1));
      }
    }
    const K = opt.darkWidthScale ?? 1.6;  // DeepCrack 学習画像の正解幅で校正

    // 7. 形状評価
    const cracks = [];
    const finalLabels = new Int32Array(w * h);
    for (const c of comps) {
      if (!keep[c.id]) continue;
      const pix = skelPix.get(c.id) || [];
      if (!pix.length) continue;
      const length = skeletonLength(skel, w, pix);
      const widths = pix.map((i) => Math.max(1, 2 * dist[i] - 1)).sort((a, b) => a - b);
      const meanWidth = c.area / length;
      const maxWidth = widths[Math.floor(widths.length * 0.95)] || widths[widths.length - 1];
      const elong = length / Math.max(1, meanWidth);
      if (length < minLen || elong < opt.minElongation) continue;

      // 幅(暗さベース、校正済み)。暗い本体が見つからなければ領域の幅を使う
      let meanWidthPx = meanWidth, maxWidthPx = maxWidth, widthSource = "region";
      const cw = coreWidths.get(c.id), ca = coreArea.get(c.id) || 0;
      if (opt.widthFromDarkness !== false && cw && cw.length >= 0.3 * pix.length && ca > 0) {
        cw.sort((a, b) => a - b);
        meanWidthPx = Math.min(meanWidth, K * cw.reduce((a, b) => a + b, 0) / cw.length);
        maxWidthPx = Math.min(maxWidth, K * (cw[Math.floor(cw.length * 0.95)] || cw[cw.length - 1]));
        widthSource = "darkness";
      }

      // ひびの暗さ(コントラスト)
      let contrast = 0;
      for (const i of pix) contrast += diff[i];
      contrast /= pix.length;

      cracks.push({
        id: c.id,
        bbox: { x: c.minX, y: c.minY, w: c.maxX - c.minX + 1, h: c.maxY - c.minY + 1 },
        area: c.area,
        lengthPx: length,
        meanWidthPx,
        maxWidthPx,
        widthSource,
        contrast,
      });
    }
    cracks.sort((a, b) => b.lengthPx - a.lengthPx);
    const ids = new Map(cracks.map((c, n) => [c.id, n + 1]));
    for (let i = 0; i < labels.length; i++) {
      const n = ids.get(labels[i]);
      if (n && cand[i]) finalLabels[i] = n;
    }
    cracks.forEach((c, n) => { c.no = n + 1; delete c.id; });

    let crackPixels = 0;
    for (let i = 0; i < finalLabels.length; i++) if (finalLabels[i]) crackPixels++;

    return {
      width: w,
      height: h,
      cracks,
      labels: finalLabels,   // 画素ごとのひび番号(0=なし)
      rawMask: mask,          // 足切り前の二値画像
      coverage: crackPixels / (w * h),
      threshold: thr,
    };
  }

  /**
   * 判定(実寸がわかる場合のみ幅で判定)
   *  - 0.3mm未満: ヘアクラック(経過観察)
   *  - 0.3〜0.5mm未満: 要注意(雨水侵入の可能性)
   *  - 0.5mm以上: 要点検(構造クラックの可能性、専門家に相談)
   */
  function classify(maxWidthMm) {
    if (maxWidthMm == null) return { level: "unknown", label: "幅不明", color: "#e11d48" };
    if (maxWidthMm < 0.3) return { level: "low", label: "ヘアクラック", color: "#eab308" };
    if (maxWidthMm < 0.5) return { level: "mid", label: "要注意", color: "#f97316" };
    return { level: "high", label: "要点検", color: "#dc2626" };
  }

  global.CrackDetector = { detect, classify, DEFAULTS };
})(typeof window !== "undefined" ? window : globalThis);
