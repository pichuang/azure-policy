#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/policy-common.sh
source "$SCRIPT_DIR/utils/policy-common.sh"

POLICY_NAME="${POLICY_NAME:-虛擬資料中心原則}"
DISPLAY_NAME="${DISPLAY_NAME:-虛擬資料中心原則}"
DESCRIPTION="${DESCRIPTION:-虛擬資料中心原則，專門進行自動化變更和修復以符合規範}"
MANAGEMENT_GROUP_ID="${MANAGEMENT_GROUP_ID:-}"
INITIATIVE_CATEGORY="${INITIATIVE_CATEGORY:-Regulatory Compliance}"

usage() {
  cat <<'EOF'
用法：
  ./1-create-dummy-policy.sh [options]

可選參數：
  --policy-set-name         Initiative 名稱，預設為「虛擬資料中心原則」。
  --display-name            Initiative 顯示名稱，預設與名稱相同。
  --description             Initiative 描述。
  --management-group        Management Group 名稱，未提供時預設使用 tenant ID。
  --initiative-category     Initiative metadata.category，預設為 Regulatory Compliance。
  -h, --help                顯示說明。

也可透過環境變數設定：
  POLICY_NAME, DISPLAY_NAME, DESCRIPTION, MANAGEMENT_GROUP_ID, INITIATIVE_CATEGORY
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --policy-set-name)
        POLICY_NAME="$2"
        shift 2
        ;;
      --display-name)
        DISPLAY_NAME="$2"
        shift 2
        ;;
      --description)
        DESCRIPTION="$2"
        shift 2
        ;;
      --management-group)
        MANAGEMENT_GROUP_ID="$2"
        shift 2
        ;;
      --initiative-category)
        INITIATIVE_CATEGORY="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "不支援的參數：$1"
        usage
        exit 1
        ;;
    esac
  done
}

parse_args "$@"

require_command az
ensure_azure_login

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

MANAGEMENT_GROUP_ID="$(resolve_management_group_id "$MANAGEMENT_GROUP_ID")"
build_management_group_scope_args "$MANAGEMENT_GROUP_ID"

if az policy set-definition show --name "$POLICY_NAME" "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" >/dev/null 2>&1; then
  echo "原則集已存在，略過 placeholder Initiative 建立：$POLICY_NAME"
  exit 0
fi

# 2. 建立 Dummy Policy 定義
echo "建立 Dummy Policy..."
if az policy definition show --name "DummyScarecrowPolicy" "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" >/dev/null 2>&1; then
  DUMMY_POLICY_ID="$(az policy definition show \
    --name "DummyScarecrowPolicy" \
    "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" \
    --query id -o tsv)"
else
  DUMMY_POLICY_ID=$(az policy definition create \
    --name "DummyScarecrowPolicy" \
    --display-name "Dummy Scarecrow Policy" \
    --description "This is a dummy policy that does nothing, used solely as a placeholder for an Initiative." \
    --mode "All" \
    --rules dummy-policy-rule.json \
    "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" \
    --query id -o tsv)
fi

# 3. 產生 Initiative 定義檔
cat <<EOF > scarecrow-initiative.json
[
  {
  "policyDefinitionId": "${DUMMY_POLICY_ID}",
  "policyDefinitionReferenceId": "DummyScarecrowPolicy"
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
  "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" \
  --metadata scarecrow-initiative-metadata.json \
  --definitions scarecrow-initiative.json

# 5. 清理暫存檔
rm dummy-policy-rule.json scarecrow-initiative.json scarecrow-initiative-metadata.json
echo "Dummy policy '${POLICY_NAME}' 已成功建立！"