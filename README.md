# 過去の地震情報マップ

地図上に過去の地震情報を表示するシンプルな静的Webサイトです。
[USGS Earthquake Hazards Program](https://earthquake.usgs.gov/) の地震カタログAPIから
データを取得し、[Leaflet](https://leafletjs.com/) を使って地図上に表示します。

## 機能

- 地域(日本周辺 / 世界全体)、期間、最小マグニチュードで検索
- マグニチュードに応じた色・大きさのマーカー表示
- マーカークリックで発生日時・マグニチュード・深さなどの詳細をポップアップ表示
- 検索結果のリスト表示(クリックで地図を該当地点へ移動)

## 使い方

ビルド不要の静的サイトです。ブラウザで `index.html` を開くか、簡易サーバーで配信してください。

```bash
python3 -m http.server 8000
```

その後 `http://localhost:8000` にアクセスします。

## ファイル構成

- `index.html` - ページ構造
- `style.css` - スタイル
- `script.js` - 地震データ取得・地図描画ロジック

## データソース

地震データは [USGS FDSN Event Web Service](https://earthquake.usgs.gov/fdsnws/event/1/) から取得しています。
