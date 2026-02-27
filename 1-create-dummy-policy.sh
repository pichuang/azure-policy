#!/bin/bash

set -euo pipefail

POLICY_NAME="稻草人原則集"
DISPLAY_NAME="稻草人原則集"
DESCRIPTION="稻草人原則集，專門進行自動化變更和修復以符合規範"
MANAGEMENT_GROUP_ID="${MANAGEMENT_GROUP_ID:-}"
INITIATIVE_CATEGORY="${INITIATIVE_CATEGORY:-Regulatory Compliance}"

# 1. 建立一個簡單的政策規則，檢查資源是否有標籤 dummy=True
cat <<EOF > dummy-policy-rule.json
{
  "if": {
    "field": "tags['dummy']",
    "equals": "True"
  },
  "then": {
    "effect": "audit"
  }
}
EOF

if ! az account show >/dev/null 2>&1; then
  echo "尚未登入 Azure，請先執行：az login"
  exit 1
fi

if [[ -z "$MANAGEMENT_GROUP_ID" ]]; then
  MANAGEMENT_GROUP_ID="$(az account show --query tenantId -o tsv)"
fi

scope_args=(--management-group "$MANAGEMENT_GROUP_ID")

# 2. 建立 Dummy Policy 定義
echo "建立 Dummy Policy..."
DUMMY_POLICY_ID=$(az policy definition create \
  --name "DummyScarecrowPolicy" \
  --display-name "Dummy Scarecrow Policy" \
  --description "This is a dummy policy that does nothing, used solely as a placeholder for an Initiative." \
  --mode "All" \
  --rules dummy-policy-rule.json \
  "${scope_args[@]}" \
  --query id -o tsv)

# 3. 產生 Initiative 定義檔
cat <<EOF > scarecrow-initiative.json
[
  {
    "policyDefinitionId": "${DUMMY_POLICY_ID}"
  }
]
EOF

cat <<EOF > scarecrow-initiative-metadata.json
{
  "category": "${INITIATIVE_CATEGORY}"
}
EOF

# 4. 建立正式的政策集 (Initiative)
az policy set-definition create \
  --name "${POLICY_NAME}" \
  --display-name "${DISPLAY_NAME}" \
  --description "${DESCRIPTION}" \
  "${scope_args[@]}" \
  --metadata scarecrow-initiative-metadata.json \
  --definitions scarecrow-initiative.json

# 5. 清理暫存檔
rm dummy-policy-rule.json scarecrow-initiative.json scarecrow-initiative-metadata.json
echo "Dummy policy '${POLICY_NAME}' 已成功建立！"