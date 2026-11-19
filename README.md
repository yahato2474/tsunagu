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

## ライセンス

MIT License。詳しくは [LICENSE](LICENSE) を参照。
