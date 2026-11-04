# DECISIONS — rec-tube

## D1. 既存 rec.swift を改善する（新規作成しない）
- 選択: リポジトリ直下の rec.swift を取り込んで改善する
- 却下: リファレンスだけを設計メモとして新規実装
- 理由: `--url` モードが既に実装済みで、Swift 6.3 でビルドできることを確認した

## D2. 今回のマイルストーンは実装まで行う
- 選択: 要件確定後、無人ループで実装まで進める。資料取得は research に含める
- 却下: 資料と環境の準備だけで止める

## D3. 改善範囲は 4 項目すべて
- 選択: データ保全 / 広告境界 / 長時間追従 / ビルド整備

## D4. 最小 OS は macOS 26
- 選択: bundleIDs と isProcessRestoreEnabled を使い、PID 列挙と前方一致をやめる
- 却下: 14.4 以上の維持（2 系統の保守が必要で、14.x の動作をこの Mac で確認できない）

## D5. 他タブ音の混入は README に明記するだけ
- 選択: コード変更なし。tap は Chrome 全体を録る制約として記載する
- 却下: 開始時の検出と警告（ベストエフォートで録音中の混入は防げない）、
  --user-data-dir での別起動（ログインのやり直しが必要）

## D6. テストは既存の Xcode で swift test を行う
- 選択: /Applications/Xcode.app（26.1.1）を DEVELOPER_DIR で指定して使う。
  ユーザーは「Xcode を導入する」を選んだが、調査で導入済みと判明したため追加導入は不要。
  xcode-select は sudo が要るので変更しない。Swift Testing の動作を確認済み
- 却下: 自前のテスト実行ファイル、ビルド確認のみ

## D7. SwiftPM に分割する
- 選択: ロジックのライブラリと CLI 実行ターゲットに分ける。Info.plist はリンカ設定で埋め込む
- 却下: 単一ファイル維持（テストから内部ロジックを呼びにくい）

## D8. 実機録音もループ内で検証する
- 選択: verify で実際に録音する。起動前に Chrome の JS 許可とシステム音声の許可を済ませる
- 却下: 手動チェックリストのみ

## D9. 堅牢性を受け入れ基準に入れる

## D10. ライブ配信は非対応で即エラー
- 却下: Ctrl-C まで録音（広告や頭出しの扱いを別途詰める必要がある）

## D11. 実機検証はローカルページと YouTube の両方
- 選択: 広告境界は決定的なローカル検証ページで測り、YouTube は実環境の疎通に使う
- 却下: どちらか一方のみ（YouTube だけでは広告を再現できず、ローカルだけでは DOM 変更を検出できない）

## D12. 広告境界は混入ゼロ優先
- 却下: 本編欠落ゼロ優先、両方 0.5 秒以内（verify が差し戻し続けるリスク）

## D13. デバイス切り替えとスリープでは録音を止めて保存
- 却下: 一時停止して tap を作り直し再開（復旧処理が最も複雑）

## D14. 既存モードを維持
- 却下: --url への一本化

## D15. --url の既定ファイル名は動画タイトル。上書きはしない
- 却下: rec-日時.m4a の維持（後から中身が分かりにくい）

## D16. 無音は警告して続行し、全編無音なら非ゼロ終了
- 却下: 数秒で中止（冒頭が静かな動画を録音できない）

## D17. --url は video 要素があれば許可
- 却下: YouTube 限定（ローカル検証ページ用にテスト専用の抜け道が必要になる）

## D18. 実行パターン
- エンジン: すべて Claude（engine=claude、phase_engines={}）
- サブエージェント: auto、振り返り: 有効
- モデル: research / plan / verify / reflect は claude-fable-5-1、impl は claude-opus-5
- research.targets: similar_oss、official_docs、local_projects

## 調査で確認した事実（2026-11-04）
- macOS 26.5.1 / Swift 6.3.2（CLT）。xcode-select は CLT を指すが Xcode 26.1.1 も導入済み
- `swiftc -O rec.swift` は警告 2 件で成功。既定の minos は 26.0
- rec.swift のビルド手順が参照する Info.plist はリポジトリに存在しない
- CLT では `import XCTest` も `import Testing` も失敗する。DEVELOPER_DIR で Xcode を指定すれば成功する
- Chrome の allow_javascript_apple_events は Default プロファイルで未設定。起動前に有効化が必要
- シェルは tmux 上。システム音声の許可の付与先は要確認
- ffmpeg / yt-dlp / whisper は未導入
