# アプリアイコン

## 採用案

アイコン比較案 v4 から **G-1「緋燼」（Fold 折面）** を採用した。黒曜石の背景に、灰白の上帯とガーネットの下帯を折り重ねた案である。

## ファイル

- `docs/prototypes/melete-icon-options.html`: 比較に使った v4 の HTML。外部参照のない単一ファイルで、受け取った内容をそのまま保存している
- `docs/prototypes/melete-icon-g1.svg`: G-1 の単体ソース（1024×1024）。HTML の `symbol#g1` と、それが参照する `g1-*` の defs（角丸、グラデーション、フィルタ、クリップ）を抜き出した。角丸の外側の余白は透明のまま
- `Melete/Assets.xcassets/AppIcon.appiconset/`: macOS 標準の AppIcon。16・32・128・256・512pt の 1x/2x、計10枚（最大 1024px）

## サイズ別 PNG の作り方

単体 SVG を正とし、各サイズの PNG はこの SVG から書き出す。ぼかしや影のフィルタ（`feGaussianBlur`、`feDropShadow`、`feComposite`）を正しく解釈するレンダラを使う。書き出した画像は比較 HTML 上の G-1 と見比べて確認する。

| ファイル | ピクセル |
| --- | --- |
| `icon_16x16.png` | 16 |
| `icon_16x16@2x.png`, `icon_32x32.png` | 32 |
| `icon_32x32@2x.png` | 64 |
| `icon_128x128.png` | 128 |
| `icon_128x128@2x.png`, `icon_256x256.png` | 256 |
| `icon_256x256@2x.png`, `icon_512x512.png` | 512 |
| `icon_512x512@2x.png` | 1024 |

`project.yml` の `Melete` ターゲットで `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` を指定している。設定を反映するには `xcodegen generate` でプロジェクトを再生成する。
