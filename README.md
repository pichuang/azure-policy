# Azure Policy

## 操作順序

建議依照以下順序操作：

1. 部署：`./deploy-policies.sh`，建立或更新 initiative 與 policy definitions。
2. 驗證：`./validate-policy.sh`，先驗證單一 policy 定義是否正確。
3. 排查：`./diagnose-policy.sh`，檢查 definition、initiative、assignment 與 compliance。
4. 清理：`./cleanup-duplicate-policies.sh`，清除歷史重複部署且已無引用的 definitions。

## 腳本一覽

- `./deploy-policies.sh`：標準部署入口，負責 initiative 建立或更新、單檔驗證串接與 policy definitions 同步。
- `./validate-policy.sh`：單一 policy 驗證工具，支援本地結構檢查與 Azure smoke test。
- `./diagnose-policy.sh`：單一 policy 排查與 remediation 工具，檢查 definition、initiative、assignment、compliance，並可直接觸發修復流程。
- `./cleanup-duplicate-policies.sh`：重複 definition 清理工具，分析同 displayName 的重複項目並安全刪除舊版本。

## 部署

腳本：`./deploy-policies.sh`

用途：一次完成 initiative 建立、policy 驗證與 policy definitions 更新，且可重複執行。

```bash
./deploy-policies.sh \
  --policy-set-name "虛擬資料中心原則" \
  --display-name "虛擬資料中心原則" \
  --description "虛擬資料中心原則，專門進行自動化變更和修復以符合規範" \
  --management-group <management-group-id> \
  --initiative-category "Regulatory Compliance"
```

若要套用到其他環境，只需要調整參數或同名環境變數：

- POLICY_SET_NAME
- DISPLAY_NAME
- DESCRIPTION
- POLICY_DIR
- NAME_PREFIX
- MANAGEMENT_GROUP_ID
- INITIATIVE_CATEGORY

建議做法：

- 新部署使用 `./deploy-policies.sh`。
- 後續更新同樣使用 `./deploy-policies.sh`。
- 不需要再分別執行建立 initiative 與更新 policies 的舊腳本。

## 驗證

腳本：`./validate-policy.sh`

用途：先在本地驗證單一 policy JSON，再視需要做 Azure smoke test。

本地驗證：

```bash
./validate-policy.sh \
  --policy-file "./policies/自動為 Storage Account 停用匿名存取.json" \
  --local-only
```

Azure smoke test：

```bash
./validate-policy.sh \
  --policy-file "./policies/自動為 Storage Account 停用匿名存取.json" \
  --azure-smoke-test \
  --management-group <management-group-id>
```

驗證內容包含：

- JSON 格式是否正確
- displayName 是否與檔名一致
- policyType、mode、metadata、policyRule 必要欄位是否存在
- effect 參數與 then.effect 是否一致
- Azure smoke test 時，是否能成功建立暫時的 policy definition

## 排查

腳本：`./diagnose-policy.sh`

用途：將手動排查流程整合成單一腳本，依序檢查：

- 本地 policy 結構
- Azure policy definition 是否存在
- initiative 是否包含對應的 policyDefinitionReferenceId
- assignment 參數、scope、effect、identity
- compliance state
- 可直接執行 remediation，並輪詢結果與 deployment 摘要

範例：

```bash
./diagnose-policy.sh \
  --policy-file "./policies/自動為 Storage Account 停用匿名存取.json" \
  --management-group <management-group-id> \
  --assignment <assignment-name> \
  --resource "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>" \
  --trigger-scan
```

若要直接執行 remediation：

```bash
./diagnose-policy.sh \
  --policy-file "./policies/自動為 Storage Account 停用匿名存取.json" \
  --management-group <management-group-id> \
  --assignment <assignment-name> \
  --run-remediation
```

若要限制 remediation 範圍或調整輪詢行為：

```bash
./diagnose-policy.sh \
  --policy-file "./policies/自動為 Storage Account 停用匿名存取.json" \
  --management-group <management-group-id> \
  --assignment <assignment-name> \
  --run-remediation \
  --location-filter japaneast \
  --resource-discovery-mode ReEvaluateCompliance \
  --poll-interval 10 \
  --poll-timeout 1800
```

## 清理

腳本：`./cleanup-duplicate-policies.sh`

用途：協助盤點歷史重複部署的 policy definitions，並只刪除安全可刪的舊 definition。

功能包含：

- 自動列出同 displayName 的重複 definitions
- 標示哪些仍被 initiative 使用
- 標示哪些仍被 assignment 直接使用
- 預設只做分析，不會直接刪除
- 僅在可安全判定首選 definition 時，刪除未被使用的舊 definition

先做 dry-run：

```bash
./cleanup-duplicate-policies.sh \
  --management-group <management-group-id>
```

只分析特定 displayName：

```bash
./cleanup-duplicate-policies.sh \
  --management-group <management-group-id> \
  --display-name "自動為虛擬機器啟用主機端加密 (Encryption at host)"
```

確認後再執行刪除：

```bash
./cleanup-duplicate-policies.sh \
  --management-group <management-group-id> \
  --apply-delete
```

## Remediation task 注意事項

- 若 remediation task 對應的 assignment 已被刪除，Azure 入口網站不會顯示該 remediation task。
- 若 remediation task 是針對 initiative 內的單一 policy 建立，並指定了 policyDefinitionReferenceId，該值必須與 initiative definition 內的 policyDefinitionReferenceId 完全相同。
- 本 repo 的 `./deploy-policies.sh` 會將每個政策的 policyDefinitionReferenceId 設為穩定的 policy name，也就是 NAME_PREFIX-雜湊值。

## 需要手動加入

- Keys using elliptic curve cryptography should have the specified curve names
  - /providers/Microsoft.Authorization/policyDefinitions/ff25f3c8-b739-4538-9d07-3d6d25cfb255
- Keys using RSA cryptography should have a specified minimum key size
  - /providers/Microsoft.Authorization/policyDefinitions/82067dbb-e53b-4e06-b631-546d197452d9
- Keys should be backed by a hardware security module (HSM)
  - /providers/Microsoft.Authorization/policyDefinitions/587c79fe-dd04-4a5e-9d0b-f89598c7261b
- Not allowed resource types
  - /providers/Microsoft.Authorization/policyDefinitions/6c112d4e-5bc7-47ae-a041-ea2d9dccd749
- Add system-assigned managed identity to enable Guest Configuration assignments on virtual machines with no identities
- Deploy the Windows Guest Configuration extension to enable Guest Configuration assignments
- Deploy the Linux Guest Configuration extension to enable Guest Configuration assignments on Linux VMs
