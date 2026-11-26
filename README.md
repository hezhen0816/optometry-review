# 驗光國考錯題本

An unofficial SwiftUI study app for Taiwan’s optometrist exam, with a mistake book, FSRS spaced repetition, and per-subject progress. Python scripts can build a local question bank from public Ministry of Examination PDFs. This repository is unaffiliated with the Ministry and does not redistribute exam content.

這是獨立開發的非官方專案，與考選部無隸屬或合作關係。本儲存庫不再散布考選部試題、答案、試卷 PDF 或附圖。專案將自行取得的歷屆試卷轉成可練習的本機題庫，用作答紀錄安排複習，並追蹤各科的弱點。

## 功能

- 錯題本、收藏、作答紀錄與 FSRS-6 間隔複習。
- 分科與分單元統計、歷屆試卷練習，以及題量足夠時的模擬考。
- 選用的 AI 解析與追問。伺服器比對解析回報的答案與題庫答案，再決定是否快取。
- 以 Python 模板產生計算練習題，包含程式驗算、選項檢查、選用的模型盲解抽查與 SwiftUI 圖解。

## 架構

```text
考選部公開查詢平臺 → Playwright 索引 → 下載 PDF → Poppler 轉成 JSON 與附圖
                                                         ↓
本機題庫或虛構範例 → SwiftUI iPhone／iPad App → SwiftData 學習紀錄
                         ↕ 選用的 HTTP API
                 Python AI 解析伺服器 → SQLite 與 Anthropic API

本機題庫與自備考點標籤 → Python 計算模板 → 驗算與選用盲解 → App AI 練習
```

## 使用虛構範例

需要 macOS、Xcode（含 iOS SDK）及 XcodeGen。App 的最低部署目標為 iOS／iPadOS 17。

```sh
brew install xcodegen
xcodegen generate --spec ios/project.yml
open ios/OptometryReview.xcodeproj
```

在 Xcode 選擇 `OptometryReview` scheme 和執行目的地。要安裝到實體裝置，請選擇自己的簽署團隊與 Bundle Identifier。預設建置離線使用，內含五道明確標示為虛構的自寫範例，其中一題展示 AI 練習資料格式。範例足以試用作答、錯題及單元相關功能，完整模擬考需自行取得題庫。

## 從考選部重建本機題庫

準備 Python 3.12、Google Chrome 與 Poppler（macOS 可用 `brew install poppler`）。從儲存庫根目錄執行以下指令。爬蟲使用系統安裝的 Chrome，程式中的範圍為西元 2016 至 2026 年。

```sh
python3.12 -m venv "$HOME/.venvs/optometry-review"
source "$HOME/.venvs/optometry-review/bin/activate"
python -m pip install playwright
python scripts/crawl_index.py
python scripts/fetch_exams.py
python scripts/parse_exam.py --all
```

- `crawl_index.py` 從考畢試題查詢平臺建立驗光師與驗光生的試卷連結索引 `題庫/index.json`。 [考選部考畢試題查詢平臺](https://wwwq.moex.gov.tw/exam/wFrmExamQandASearch.aspx)
- `fetch_exams.py` 依索引下載試題、答案及已公布的更正答案至 `題庫/原始/`。
- `parse_exam.py --all` 轉換驗光師試卷，將題目寫到 `題庫/轉檔/`，附圖寫到 `題庫/圖/`。更正答案優先。請檢查輸出摘要中的 `ERROR`、`FAIL` 和 `needsReview`，並與原始 PDF 核對。可自行建立 `題庫/人工修正.json`，格式以轉檔程式的 `load_overrides` 為準。

使用自建題庫時，在 Xcode 的 App target 加入使用者自訂建置設定 `OPTO_USE_LOCAL_BANK=1`，或在 `xcodebuild` 指令尾端加上同一設定。建置會從 `題庫/` 讀取資料。版本控制已忽略該目錄。請勿將含歷屆題庫的 App 套件當成此儲存庫的公開發行檔。

轉檔產物支援歷屆題練習。分單元標籤、考點、講義與 AI 練習題需要另備對應的資料檔，範例結構見 `examples/` 和設計文件。批次轉檔與 App 題池皆限定驗光師。

## 選用的 AI 服務

啟用前一節的 Python 環境，再安裝伺服器依賴。從根目錄執行：

```sh
python -m pip install -r server/requirements.txt
mkdir -p .local
python scripts/build_bank_bundle.py .local/bank.json --bank-dir examples
cp .env.example .env
```

在自己的 `.env` 設定 `ANTHROPIC_API_KEY` 與 `OPTO_AI_TOKEN`。管理端點另用選填的 `OPTO_AI_OWNER_TOKEN`，其值必須與 App 權杖不同。建立真實題庫後，可將上面的 `--bank-dir examples` 改為 `--bank-dir 題庫`。需要倫理法規的引用時，可用 `python scripts/fetch_laws.py` 自行產生 `server/laws/`。

```sh
set -a
. ./.env
set +a
lsof -nP -iTCP:"$OPTO_AI_PORT" -sTCP:LISTEN
# 確認埠未使用後啟動，可用 Ctrl-C 停止。
python server/app.py
```

服務只監聽迴路介面，可從同一台機器查詢 `/healthz`。如需從實體裝置連線，請自行提供可達的 HTTPS 端點，並在 Xcode 的 Run scheme 環境變數中填入 `OPTO_AI_BASE_URL` 和 `OPTO_AI_TOKEN`。選填的 `OPTO_AI_FALLBACK_URLS` 接受逗號分隔的備援網址。Anthropic 金鑰只供 Python 程式使用。啟用 AI 解析時，App 會把所選題目與提問傳送到自架服務，服務會將生成所需的內容送給模型供應商。接上服務後，使用紀錄回傳預設開啟，可在 App 的設定關閉。

- [AI 出題與圖解](docs/AI出題與圖解.md)
- [AI 解析批次預先產生](docs/AI解析預先產生.md)

## 測試

先維持範例題庫的預設建置設定。可用 Xcode 執行 `OptometryReview` scheme 的單元測試，或以通用 iOS 裝置目標編譯 App 與測試套件。

```sh
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/OptometryReview.xcodeproj -scheme OptometryReview \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build-for-testing
python -m unittest discover -s server
python -m unittest discover -s scripts/ai_questions
```

Python 測試使用虛構資料、迴路介面與模擬的模型回應。完整歷屆題的模板回放測試需自備已校對且含考點標籤的題庫，並設 `OPTO_TEST_LOCAL_BANK=1`。

## 限制與資料

- PDF 版型、公式和附圖可能影響擷取結果。以考選部原始試卷與更正答案為準。
- AI 解說與盲解抽查仍可能出錯。請自行對照課本與官方答案。
- 公開建置預設使用本機 SwiftData。若要自行啟用 iCloud 同步，請設定自己的 CloudKit container 與簽署能力，在 `ios/project.yml` 的 App `info.properties` 加入 `OptometryCloudContainer` 並重建 Xcode 專案，並用 Debug 啟動參數 `-iCloud` 驗證。
- 原始碼採 MIT 授權，FSRS 參考實作與測試向量的來源見 [第三方授權聲明](THIRD_PARTY_NOTICES.md)。

以 Claude Code、Codex 等 AI 代理協作開發：需求、架構與技術選擇由作者與 AI 討論後決定，程式碼主要由 AI 撰寫。
