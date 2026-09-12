const REGIONS = {
  japan: { minlatitude: 24, maxlatitude: 46, minlongitude: 122, maxlongitude: 146, center: [37.5, 137], zoom: 5 },
  world: { minlatitude: -90, maxlatitude: 90, minlongitude: -180, maxlongitude: 180, center: [20, 140], zoom: 2 },
};

const USGS_ENDPOINT = "https://earthquake.usgs.gov/fdsnws/event/1/query";

const map = L.map("map", { worldCopyJump: true }).setView(REGIONS.japan.center, REGIONS.japan.zoom);
L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
  attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
  maxZoom: 18,
}).addTo(map);

let markerLayer = L.layerGroup().addTo(map);

const form = document.getElementById("search-form");
const regionSelect = document.getElementById("region");
const startDateInput = document.getElementById("start-date");
const endDateInput = document.getElementById("end-date");
const minMagInput = document.getElementById("min-mag");
const minMagValueLabel = document.getElementById("min-mag-value");
const searchBtn = document.getElementById("search-btn");
const statusEl = document.getElementById("status");
const resultCountEl = document.getElementById("result-count");
const quakeListEl = document.getElementById("quake-list");

function formatDateForInput(date) {
  return date.toISOString().slice(0, 10);
}

function setDefaultDateRange() {
  const today = new Date();
  const past = new Date();
  past.setDate(today.getDate() - 30);
  endDateInput.value = formatDateForInput(today);
  startDateInput.value = formatDateForInput(past);
  endDateInput.max = formatDateForInput(today);
  startDateInput.max = formatDateForInput(today);
}

function magnitudeColor(mag) {
  if (mag >= 6) return "#7b1fa2";
  if (mag >= 5) return "#f44336";
  if (mag >= 4) return "#ff9800";
  if (mag >= 3) return "#ffeb3b";
  return "#4caf50";
}

function magnitudeRadius(mag) {
  const safeMag = Number.isFinite(mag) ? mag : 1;
  return Math.max(4, safeMag * 3);
}

function formatDateTime(ms) {
  const date = new Date(ms);
  return date.toLocaleString("ja-JP", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function buildQueryUrl() {
  const region = REGIONS[regionSelect.value];
  const params = new URLSearchParams({
    format: "geojson",
    starttime: startDateInput.value,
    endtime: endDateInput.value,
    minmagnitude: minMagInput.value,
    orderby: "time",
    limit: "1000",
    minlatitude: region.minlatitude,
    maxlatitude: region.maxlatitude,
    minlongitude: region.minlongitude,
    maxlongitude: region.maxlongitude,
  });
  return `${USGS_ENDPOINT}?${params.toString()}`;
}

function clearResults() {
  markerLayer.clearLayers();
  quakeListEl.innerHTML = "";
  resultCountEl.textContent = "0";
}

function renderQuakes(features) {
  clearResults();
  resultCountEl.textContent = String(features.length);

  const sorted = [...features].sort((a, b) => b.properties.time - a.properties.time);

  sorted.forEach((feature) => {
    const [lon, lat, depth] = feature.geometry.coordinates;
    const { mag, place, time, url } = feature.properties;
    const color = magnitudeColor(mag);

    const marker = L.circleMarker([lat, lon], {
      radius: magnitudeRadius(mag),
      color,
      fillColor: color,
      fillOpacity: 0.6,
      weight: 1,
    });

    const popupHtml = `
      <strong>${place ?? "場所不明"}</strong><br>
      発生日時: ${formatDateTime(time)}<br>
      マグニチュード: ${mag ?? "不明"}<br>
      深さ: ${depth != null ? depth.toFixed(1) + " km" : "不明"}<br>
      <a href="${url}" target="_blank" rel="noopener">USGS詳細ページ</a>
    `;
    marker.bindPopup(popupHtml);
    marker.addTo(markerLayer);

    const li = document.createElement("li");
    li.innerHTML = `
      <span class="mag" style="color:${color}">M${mag != null ? mag.toFixed(1) : "?"}</span>
      <span class="place">${place ?? "場所不明"}</span>
      <span class="time">${formatDateTime(time)}</span>
    `;
    li.addEventListener("click", () => {
      map.setView([lat, lon], 7);
      marker.openPopup();
    });
    quakeListEl.appendChild(li);
  });
}

function setStatus(message, isError = false) {
  statusEl.textContent = message;
  statusEl.classList.toggle("error", isError);
}

async function searchQuakes() {
  if (!startDateInput.value || !endDateInput.value) {
    setStatus("開始日と終了日を指定してください。", true);
    return;
  }
  if (startDateInput.value > endDateInput.value) {
    setStatus("開始日は終了日より前にしてください。", true);
    return;
  }

  searchBtn.disabled = true;
  setStatus("検索中...");

  try {
    const response = await fetch(buildQueryUrl());
    if (!response.ok) {
      throw new Error(`HTTPエラー: ${response.status}`);
    }
    const data = await response.json();
    renderQuakes(data.features ?? []);
    setStatus(`${data.features?.length ?? 0}件の地震データを取得しました。`);

    const region = REGIONS[regionSelect.value];
    map.setView(region.center, region.zoom);
  } catch (error) {
    console.error(error);
    clearResults();
    setStatus("地震データの取得に失敗しました。時間をおいて再度お試しください。", true);
  } finally {
    searchBtn.disabled = false;
  }
}

minMagInput.addEventListener("input", () => {
  minMagValueLabel.textContent = Number(minMagInput.value).toFixed(1);
});

regionSelect.addEventListener("change", () => {
  const region = REGIONS[regionSelect.value];
  map.setView(region.center, region.zoom);
});

form.addEventListener("submit", (event) => {
  event.preventDefault();
  searchQuakes();
});

setDefaultDateRange();
searchQuakes();
