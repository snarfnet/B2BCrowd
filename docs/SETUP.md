# B2B CROWD セットアップ

## ビルド

```sh
brew install xcodegen
xcodegen generate
open B2BCrowd.xcodeproj
```

## 音楽ソース

タイトル画面・ロビーの **MUSIC SOURCE** で選びます。セッション画面の左上にも、いま使っているソース（APPLE MUSIC / AUDIUS / DEMO）が出ます。

| ソース | 必要なもの | 再生のしかた |
|---|---|---|
| APPLE MUSIC | Apple Music の許可とサブスクリプション。Developer の App ID で **MusicKit App Service** を有効化 | MusicKit の `ApplicationMusicPlayer` |
| AUDIUS | ネット接続だけ（登録不要・無料） | 公式 API `GET /v1/tracks/{id}/stream?no_redirect=true` が返す URL を `AVPlayer` で再生 |
| DEMO | なし | 架空の曲。音は鳴らない |

ソースを切り替えると、鳴っているプレイヤーを止めてから切り替えます（2つが同時に鳴ることはありません）。

## Audius Developer 設定

API キーが無くても `app_name=B2BCrowd` を付けて読み取り専用で使えます。公開前は API キーを取っておくと安心です（Free プランの上限は 10 req/s・月50万リクエスト）。

1. https://api.audius.co/plans で **Create API Key** を押し、API Key を発行する（Audius アカウントでログイン）。
2. `Config/Secrets.example.xcconfig` をコピーして `Config/Secrets.xcconfig` を作る。
3. `AUDIUS_API_KEY = 発行したキー` を書く。
4. `xcodegen generate` し直してビルドする。

- `Config/Secrets.xcconfig` は `.gitignore` 済みです。コミットしないでください。
- GitHub Actions では、リポジトリの Secret `AUDIUS_API_KEY` から `Config/Secrets.xcconfig` を作ってビルドします。
- 発行済みキー: Audius アカウント @snarfnet の「B2B CROWD」（2026-10-06、Free プラン）。管理は https://api.audius.co/plans
- Audius から一緒に渡される **Bearer Token / API Secret はアプリに入れません**（Audius の指示でサーバー専用）。このアプリは読み取りと再生だけなので不要です。
- キーは `Info.plist` の `AudiusAPIKey` 経由で読み、全リクエストのクエリに `api_key` を付けます（公式 SDK と同じ方式）。キーが空なら `app_name` を付けます。

参照した公式資料（2026-10 時点）:
- API リファレンス（OpenAPI）: https://api.audius.co/v1/swagger.yaml
- 開発者ドキュメント: https://docs.audius.co/ （API Plans、Image Loading & Mirrors）

## Audius 連携の作り

| ファイル | 役割 |
|---|---|
| `Music/Audius/AudiusModels.swift` | `AudiusTrack`（公式 track スキーマの必要な項目だけ）、再生可否 `AudiusPlayability`、ライセンス分類 `AudiusLicense`、除外方針 `AudiusPolicy`、エラー `AudiusError`、Trending の分類 |
| `Music/Audius/AudiusAPIClient.swift` | `/tracks/search`・`/tracks/trending`・`/tracks/{id}/stream` を呼ぶ。最短 0.15 秒間隔、同じ検索は 2 分キャッシュ（メタデータのみ） |
| `Music/Audius/AudiusPlayer.swift` | `TrackPlayer` の Audius 版（`AVPlayer`）。再生前に権利・アクセス情報を確認する |
| `Music/MusicService.swift` | `source` で Apple Music / Audius を切り替える |
| `Game/Models.swift` | `Track` が共通の曲モデル。`TrackSource.audius` を追加 |
| `Music/MusicAnalytics.swift` | 端末内だけの回数集計（検索・選曲・再生成功/失敗・平均選曲時間）。外部には送らない |

ゲーム本体（`GameEngine`）は `Track` と `TrackPlayer` しか見ないので、ターン交代・CROWD ENERGY・TIME ATTACK・SECRET TRACK・スコアは Apple Music と Audius で共通です。盛り上がりの計算に音源は使いません。

### 再生してよい曲の判定

API が返す情報だけで判断します。分からないものを「可」とは扱いません。

- `is_streamable` が true でない → 再生しない
- `is_stream_gated` が true、または `stream_conditions` がある → 再生しない（限定公開）
- `access_authorities` が空でない → 再生しない（配信元が署名で管理している曲）
- `access.stream` が false → 再生しない
- `allowed_api_keys` があり、自分のキーが含まれない → 再生しない
- `is_available` が false、`is_delete` が true → 再生しない
- `license` が null → UNKNOWN と表示。`AudiusPolicy.excludeUnknownLicense = true` にすると候補から外せる
- 地域制限は事前に分からないので、ストリーム URL の取得が 403 / 451 で返ったときにエラーとして扱う

再生できない曲は検索結果で灰色になり、SELECT が押せません。再生開始で失敗したときは罰なしで選び直しになり、セッションは続きます。

### 帰属表示

- 検索結果の各行に Audius の曲ページへのリンク（↗）を表示
- 再生中の曲に `Audius ↗`、NEXT TRACK 演出に `Source: Audius` を表示
- 検索画面の下に「音源・メタデータ提供: Audius」とリンクを表示
- 曲名・アーティスト名は API の値をそのまま表示（変えない）

### 入れていないもの

- バックグラウンド再生・ロック画面の Now Playing：セッションはアプリを閉じると一時停止する仕様のため入れていない
- クロスフェード・2曲同時再生・BPM・ピッチ・スクラッチ・ループ・録音・音源のダウンロードや保存：入れない（仕様）

## 動作確認

CI（`.github/workflows/ci.yml`）がシミュレーターで次を撮ります。

- `-shot audius`：Audius の TRENDING ELECTRONIC から再生できる曲を自動で選び、実際にストリーミングしながら DJ A → DJ B と4曲回す
- `-shot audiussearch`：Audius の TRENDING 画面

手で確かめる流れ（仕様書の TEST 1〜5）:

1. MUSIC SOURCE を AUDIUS → START → 検索して SELECT → 再生 → 相手が SELECT → 曲が終わると NEXT TRACK! → 次の曲
2. 灰色の曲は SELECT できない。再生失敗時はメッセージが出て選び直し
3. 機内モードで検索 → 「通信できませんでした」。戻すと検索できる
4. タイトルで APPLE MUSIC に戻す → Audius は止まる → Apple Music で普通に遊べる
5. SECRET TRACK で Audius の曲を選ぶ → 相手には「SECRET TRACK 🔒」→ 切り替わりで公開
