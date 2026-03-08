# Azure Policy

## 可重複利用的部署流程

建議優先使用 deploy-policies.sh，一次完成 placeholder initiative 建立與所有 policy 更新。

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

deploy-policies.sh 內部會先呼叫 1-create-dummy-policy.sh，若 initiative 已存在則繼續執行 2-update-policies.sh，因此同一套腳本可重複執行。

## 單一 Policy 驗證

新增 4-validate-policy.sh，可先在本地驗證單一 policy JSON，再視需要做 Azure smoke test。

本地驗證：

```bash
./4-validate-policy.sh \
  --policy-file "./policies/自動為 Storage Account 停用匿名存取.json" \
  --local-only
```

Azure smoke test：

```bash
./4-validate-policy.sh \
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

## Policy 排查腳本

新增 diagnose-policy.sh，可將手動排查流程整合成單一腳本，依序檢查：

- 本地 policy 結構
- Azure policy definition 是否存在
- initiative 是否包含對應的 policyDefinitionReferenceId
- assignment 參數、scope、effect、identity
- compliance state 與可選 remediation

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

## 重複 Definition 清理腳本

新增 cleanup-duplicate-policies.sh，可協助盤點歷史重複部署的 policy definitions，並只刪除安全可刪的舊 definition。

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
- 本 repo 的 2-update-policies.sh 會將每個政策的 policyDefinitionReferenceId 設為穩定的 policy name，也就是 NAME_PREFIX-雜湊值。

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

##

sqlmi vulnerability enabled

改成 safe deployment
