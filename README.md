# Tsunagu（繋ぐ）

Tailscale の端末をメニューバーに並べ、画面共有・SSH・Taildrop を 1 クリックで行う macOS アプリ（Swift / AppKit）。
端末の一覧は、メニューを開くたびに Tailscale 本体の `status --json` から取り直す。常駐中は何もしない。

## ビルドと起動

```bash
./build-app.sh
```

```bash
open build/Tsunagu.app
```

## できること

オンラインの端末ごとに、OS に合った操作が出る。

| 操作 | 対象 | 中身 |
|---|---|---|
| 画面共有 | macOS | `vnc://<MagicDNS名>` を開く |
| リモートデスクトップ | Windows | `rdp://` を開く（Windows App が受ける） |
| SSH (ターミナル) | iOS 以外 | `ssh://<MagicDNS名>` を開く |
| ファイルを送る (Taildrop) | 受信できる端末 | `tailscale file cp <ファイル> <IP>:` |
| ブラウザで開く | iOS 以外 | `https://<MagicDNS名>` |
| IP / 名前をコピー | すべて | オフラインの端末でも使える |

## 動作確認

メニューと同じ内容を文字で出して終了する。

```bash
build/Tsunagu.app/Contents/MacOS/Tsunagu --dump
```

## 前提

- `/Applications/Tailscale.app`（App Store 版 / スタンドアロン版）が入っていること
- フォルダは Taildrop で送れない（Tailscale 本体の制限）

## ログイン時の自動起動

`~/Library/LaunchAgents/local.tsunagu.plist` が、ログイン時に `open build/Tsunagu.app` を 1 回実行する。
アプリを `./build-app.sh` で作り直しても、同じ場所に置かれるので設定はそのまま使える。

やめるとき:

```bash
launchctl bootout gui/$(id -u)/local.tsunagu
```

```bash
rm ~/Library/LaunchAgents/local.tsunagu.plist
```

## Windows 版

`windows/Tsunagu.ps1` は同じ機能をタスクバーの通知領域に出す Windows 版（PowerShell + WinForms）。
ビルド不要で、スマート アプリ コントロールが有効な PC でも動く。左クリック・右クリックどちらでもメニューが開く。

| 操作 | 対象 | 中身 |
|---|---|---|
| 画面共有 (RustDesk) | iOS 以外 | RustDesk で Tailscale の IP に直接接続（`rustdesk --connect <IP>`） |
| 画面共有 (VNC) | macOS | TigerVNC などの VNC ビューアで Mac の画面共有に接続 |
| リモートデスクトップ | Windows | `mstsc /v:<MagicDNS名>` |
| SSH (ターミナル) | iOS 以外 | Windows Terminal で `ssh <MagicDNS名>` |
| ファイルを送る (Taildrop) | 受信できる端末 | `tailscale file cp <ファイル> <IP>:` |

RustDesk の IP 直接接続を使うには、接続先の RustDesk で「設定 → セキュリティ → IP直接アクセスを有効にする」をオンにする。
Tailscale の中だけで通信するので、中継サーバーを通らず速い。
それができない端末は、`%APPDATA%\Tsunagu\rustdesk-ids.json` に `{"mac-mini": "<RustDesk ID>"}` のように書くと ID で接続する。
RustDesk は `C:\Program Files\RustDesk` か `%LOCALAPPDATA%\Programs\RustDesk`（管理者権限のいらないポータブル版）に置く。

起動:

```powershell
conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows\Tsunagu.ps1
```

動作確認（メニューの内容を文字で出して終了）:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\Tsunagu.ps1 -Dump
```

ログイン時の自動起動は、メニューの「Windows 起動時に開く」で切り替える（`HKCU\...\Run` に登録）。
タスクバーに常に出すには、設定 → 個人用設定 → タスク バー → その他のシステム トレイ アイコン で「Windows PowerShell」をオンにする。

## ライセンス

MIT License。詳しくは [LICENSE](LICENSE) を参照。
