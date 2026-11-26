# AI 解析批次預先產生

`server/pregen.py` 使用 Anthropic Message Batches API，將通過答案核對的解析寫入 `/explain` 共用的 SQLite 快取。快取鍵包含題目內容，讓答案或題文更動後能重新產生解析。已快取的題與尚未結案的錯誤回報預設跳過。

在與服務相同的 Python 環境執行。以環境變數 `OPTO_AI_BANK` 指向自行建立的伺服器題庫，`OPTO_AI_DIR` 指向服務的資料目錄。批次狀態記在該目錄的 `pregen_state.json`。

1. `python server/pregen.py plan` 列出可用題數及費用估算。
2. `python server/pregen.py submit --limit 20` 提交一批題目，會呼叫外部 API 並產生費用。需提供 `ANTHROPIC_API_KEY`。
3. `python server/pregen.py status` 查看批次進度。
4. 批次結束後執行 `python server/pregen.py collect`。收集時核對輸出答案及題目雜湊，通過才存入快取。錯誤紀錄可用 `submit --retry-failed` 重試。

伺服器線上解析與批次處理共用提示、答案檢查及用量記錄。App 請求與批次 payload 的對應由 `server/test_pregen.py` 檢查。
