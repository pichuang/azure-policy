---
description: "建立新的 Azure Policy JSON 定義檔。輸入資源類型與治理需求，自動產生符合專案慣例的 policy。"
agent: "azure-policy-writer"
argument-hint: "描述你想治理的 Azure 資源與行為，例如：自動為 SQL Database 啟用透明資料加密"
tools: [read, edit, search]
---

# 建立 Azure Policy

根據使用者的需求，在 `policies/` 目錄下建立新的 Azure Policy JSON 定義檔。

## 步驟

1. 先閱讀 [policy-json.instructions.md](.github/instructions/policy-json.instructions.md) 取得格式規範
2. 搜尋 `policies/` 目錄確認是否已有類似原則，避免重複
3. 判斷最適合的效果：優先 modify → deployIfNotExists → deny
4. 產生 JSON 定義檔，存放於 `policies/` 目錄，檔名與 displayName 一致
5. 以 `jq .` 驗證 JSON 語法正確性

## 輸出要求

- JSON 檔案遵循專案結構規範
- displayName 使用中文 + 英文術語括號標註
- description 以中文說明目的、修復行為、合規理由
- modify/deployIfNotExists 效果須包含 effect 參數化（可切換 Disabled）
- 提供正確的 roleDefinitionIds
