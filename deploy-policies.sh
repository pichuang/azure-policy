#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

POLICY_SET_NAME="${POLICY_SET_NAME:-虛擬資料中心原則}"
DISPLAY_NAME="${DISPLAY_NAME:-$POLICY_SET_NAME}"
DESCRIPTION="${DESCRIPTION:-虛擬資料中心原則，專門進行自動化變更和修復以符合規範}"
POLICY_DIR="${POLICY_DIR:-$SCRIPT_DIR/policies}"
NAME_PREFIX="${NAME_PREFIX:-scarecrow}"
MANAGEMENT_GROUP_ID="${MANAGEMENT_GROUP_ID:-}"
INITIATIVE_CATEGORY="${INITIATIVE_CATEGORY:-Regulatory Compliance}"

usage() {
	cat <<'EOF'
用法：
  ./deploy-policies.sh [options]

功能：
  1. 若 Initiative 不存在則先建立 placeholder Initiative。
  2. 驗證 policies 資料夾中的每個 policy。
  3. 將所有 policy 更新到指定 Initiative。

可選參數：
  --policy-set-name         Initiative 名稱。
  --display-name            Initiative 顯示名稱。
  --description             Initiative 描述。
  --policy-dir              Policy JSON 所在資料夾，預設為 ./policies。
  --name-prefix             自訂 policy definition name 前綴，預設為 scarecrow。
  --management-group        Management Group 名稱，未提供時預設使用 tenant ID。
  --initiative-category     Initiative metadata.category，預設為 Regulatory Compliance。
  -h, --help                顯示說明。

也可透過環境變數設定：
  POLICY_SET_NAME, DISPLAY_NAME, DESCRIPTION, POLICY_DIR, NAME_PREFIX, MANAGEMENT_GROUP_ID, INITIATIVE_CATEGORY
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--policy-set-name)
				POLICY_SET_NAME="$2"
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
			--policy-dir)
				POLICY_DIR="$2"
				shift 2
				;;
			--name-prefix)
				NAME_PREFIX="$2"
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

"$SCRIPT_DIR/1-create-dummy-policy.sh" \
	--policy-set-name "$POLICY_SET_NAME" \
	--display-name "$DISPLAY_NAME" \
	--description "$DESCRIPTION" \
	--management-group "$MANAGEMENT_GROUP_ID" \
	--initiative-category "$INITIATIVE_CATEGORY"

"$SCRIPT_DIR/2-update-policies.sh" \
	--policy-set-name "$POLICY_SET_NAME" \
	--policy-dir "$POLICY_DIR" \
	--name-prefix "$NAME_PREFIX" \
	--management-group "$MANAGEMENT_GROUP_ID" \
	--initiative-category "$INITIATIVE_CATEGORY"