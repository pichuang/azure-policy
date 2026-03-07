---
description: "Azure Policy JSON 定義檔格式規範。Use when: 編輯 policy JSON, 撰寫原則, 新增 policy 定義, 修改 policy 規則"
applyTo: "policies/**/*.json"
---

# Azure Policy JSON 格式規範

## 檔案結構

```json
{
  "properties": {
    "displayName": "中文名稱 (English Term)",
    "description": "中文描述",
    "policyType": "Custom",
    "mode": "Indexed",
    "metadata": {
      "category": "服務類別",
      "version": "1.0.0"
    },
    "parameters": {},
    "policyRule": {
      "if": { },
      "then": { }
    }
  }
}
```

## 命名慣例

- 自動修復類：displayName 以「自動為」開頭
- 拒絕類：以「禁止」開頭
- 限制類：以「限制」開頭
- 強制類：以「強制」開頭
- 英文術語以括號附註，如 `(Shared Key Access)`
- 檔名與 displayName 完全一致

## 效果優先順序

1. **modify** — 首選，直接修改資源屬性
2. **deployIfNotExists** — 需部署子資源時使用
3. **deny** — 僅在無法事後補救時使用

## 條件撰寫

- 第一個條件限定 `"field": "type"`
- 陣列屬性檢查前先用 `count > 0` 確認存在
- 使用 `allOf`（AND）/ `anyOf`（OR）組合條件

## mode 選擇

- `"Indexed"` — 預設，支援標籤和位置的資源
- `"All"` — deployIfNotExists 或需評估全部資源類型時

## metadata.category

Compute / Storage / Key Vault / Network / App Service / General / Azure Update Manager / Guest Configuration / Security / Identity / Cost Management / Monitoring / Backup / Disaster Recovery / Other
