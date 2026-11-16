# AIAppshot

左右の⌘キーを同時に押すだけで、最前面のウインドウを撮影し、好きなAIアプリの入力欄に貼り付けるmacOSのメニューバーアプリです。画面の外にスクロールして隠れている本文テキストも、添付ファイルとして一緒に渡します。

ChatGPTの「Appshots」と同じことを、Claude・Codex・Muse・Grokなど、どのAIアプリにもできるようにしたものです。

> Appshots は OpenAI の機能名です。このアプリは OpenAI とは関係ありません。

## できること

| 操作 | 動き |
|---|---|
| 左右の⌘を同時押し | 最前面のウインドウを撮影し、AIアプリに貼る |
| 左右の⌥を同時押し | 範囲を選んで撮影し、矢印・四角を描いてから送る |

- **本文テキストも渡す**：Accessibility APIでウインドウの本文を取り出します。画面外にスクロールした部分も含み、サイドバーなどは除きます。範囲撮影では、画像から文字を読み取ります（OCR）
- **入力欄を汚さない**：テキストは `.txt` の添付ファイルとして貼ります。入力欄に貼る、渡さない、も選べます
- **送信はしない**：貼るだけです。一言添えてから自分で送ります
- **送り先を自動で決める**：最後に使ったAIアプリに送ります。毎回選ぶ、1つに固定する、もできます
- **左下にサムネイル**：撮った画像を左下に残します。マウスを乗せると、送る・描く・コピー・保存のボタンが出ます。ドラッグで他のアプリにも渡せます
- **矢印・四角を描く**：ドラッグで描き、Aで矢印、Rで四角に切り替え、⌘Zで戻し、Enterで送ります

## 動作環境

- macOS 14 以降
- Xcode（Swift 5.9 以降）

## ビルドとインストール

```bash
git clone https://github.com/hayabusa5/AIAppshot.git
cd AIAppshot
./build.sh
open ~/Applications/AIAppshot.app
```

`build.sh` はリリースビルドをして、`~/Applications/AIAppshot.app` にインストールします。Macに「Apple Development」の証明書があればそれで署名し、なければ ad-hoc 署名にします。ad-hoc 署名だと、ビルドし直すたびに下の権限を許可し直す必要があります。

## 必要な権限

初回起動時に、システム設定の「プライバシーとセキュリティ」で次の2つを許可してください。許可したら、メニューバーのアイコンから「再起動」を押します。

- **アクセシビリティ**：キーの同時押しの検出、本文テキストの取得、貼り付け（⌘Vの送信）に使います
- **画面収録**：ウインドウの撮影に使います

## 送り先のアプリを変える

送り先は [`Sources/AIAppshot/Targets.swift`](Sources/AIAppshot/Targets.swift) の `allTargets` に、表示名とバンドルIDで書いてあります。追加・削除したら `./build.sh` を実行してください。

アプリのバンドルIDは次のコマンドで調べられます。

```bash
osascript -e 'id of app "Claude"'
```

## しくみ

| ファイル | 役割 |
|---|---|
| `Hotkey.swift` | 修飾キーの左右を区別するビット（左⌘ `0x08`、右⌘ `0x10`、左⌥ `0x20`、右⌥ `0x40`）で同時押しを検出 |
| `Capture.swift` | ScreenCaptureKit でウインドウを撮影、`screencapture -i` で範囲撮影、Vision で文字認識 |
| `TextExtractor.swift` | Accessibility API で本文を取り出す。`AXLandmarkMain` だけをたどり、画面上の横位置から改行を復元する |
| `Paster.swift` | 送り先を前面に出し、クリップボード経由で画像とテキスト添付を貼って、元のクリップボードに戻す |
| `Overlay.swift` | 左下のサムネイル |
| `Annotator.swift` | 矢印・四角のエディタ |

## 検証用のオプション

```bash
# 指定アプリから取り出した本文を ~/Library/Caches/AIAppshot/dump-<バンドルID>.txt に書き出す
open -n -W ~/Applications/AIAppshot.app --args --dump com.anthropic.claudefordesktop

# 文字認識と図形の描き込みを試す（結果は ~/Library/Caches/AIAppshot/selftest*）
open -n -W ~/Applications/AIAppshot.app --args --selftest

# 権限なしで左下のサムネイルの見た目だけ確認する
open ~/Applications/AIAppshot.app --args --demo
```

## 限界

- テキストが取れるかどうかは、アプリの作りによります。独自に描画しているアプリでは取れないことがあります
- 貼り付けは⌘Vを送る方式です。入力欄にフォーカスが当たらないアプリでは、うまく貼れないことがあります
- 添付ファイルの貼り付けに対応していないアプリでは、ファイルのパスが文字で入ります。その場合はメニューから「入力欄に貼る」に切り替えてください

## ライセンス

MIT
