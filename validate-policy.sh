#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/policy-common.sh
source "$SCRIPT_DIR/utils/policy-common.sh"

POLICY_FILE=""
MANAGEMENT_GROUP_ID="${MANAGEMENT_GROUP_ID:-}"
LOCAL_ONLY=false
AZURE_SMOKE_TEST=false
KEEP_TEST_POLICY=false
NAME_PREFIX="${NAME_PREFIX:-policy-validate}"

usage() {
	cat <<'EOF'
用法：
  ./validate-policy.sh --policy-file <path> [options]

必要參數：
  --policy-file             要驗證的單一 policy JSON 檔案。

可選參數：
  --local-only              只做本地結構驗證，不呼叫 Azure API。
  --azure-smoke-test        額外建立暫時的 Azure Policy Definition 驗證 Azure API 可接受此 policy。
  --keep-test-policy        配合 --azure-smoke-test 使用，保留測試用 policy definition 不刪除。
  --management-group        Management Group 名稱，未提供時預設使用 tenant ID。
  --name-prefix             Azure smoke test 產生的暫存 policy 名稱前綴，預設為 policy-validate。
  -h, --help                顯示說明。

輸出說明：
  成功時回傳 0；任一必要檢查失敗時回傳非 0。
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--policy-file)
				POLICY_FILE="$2"
				shift 2
				;;
			--local-only)
				LOCAL_ONLY=true
				shift
				;;
			--azure-smoke-test)
				AZURE_SMOKE_TEST=true
				shift
				;;
			--keep-test-policy)
				KEEP_TEST_POLICY=true
				shift
				;;
			--management-group)
				MANAGEMENT_GROUP_ID="$2"
				shift 2
				;;
			--name-prefix)
				NAME_PREFIX="$2"
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

print_check() {
	local status="$1"
	local message="$2"

	printf '[%s] %s\n' "$status" "$message"
}

parse_args "$@"

for cmd in jq basename; do
	require_command "$cmd"
done

if [[ -z "$POLICY_FILE" ]]; then
	echo "缺少必要參數：--policy-file"
	usage
	exit 1
fi

if [[ ! -f "$POLICY_FILE" ]]; then
	echo "找不到 policy 檔案：$POLICY_FILE"
	exit 1
fi

if [[ "$LOCAL_ONLY" == true && "$AZURE_SMOKE_TEST" == true ]]; then
	echo "--local-only 與 --azure-smoke-test 不可同時使用"
	exit 1
fi

policy_basename="$(basename "$POLICY_FILE" .json)"

if ! jq empty "$POLICY_FILE" >/dev/null 2>&1; then
	echo "JSON 格式錯誤：$POLICY_FILE"
	exit 1
fi

declare -a errors=()
declare -a warnings=()

json_has_value() {
	local query="$1"
	jq -e "$query" "$POLICY_FILE" >/dev/null 2>&1
}

json_get_raw() {
	local query="$1"
	jq -r "$query" "$POLICY_FILE"
}

add_error() {
	errors+=("$1")
}

add_warning() {
	warnings+=("$1")
}

display_name="$(json_get_raw '.properties.displayName // empty')"
description="$(json_get_raw '.properties.description // empty')"
policy_type="$(json_get_raw '.properties.policyType // empty')"
mode="$(json_get_raw '.properties.mode // empty')"
metadata_category="$(json_get_raw '.properties.metadata.category // empty')"
metadata_version="$(json_get_raw '.properties.metadata.version // empty')"
effect_parameter_type="$(json_get_raw '.properties.parameters.effect.type // empty')"
then_effect="$(json_get_raw '.properties.policyRule.then.effect // empty')"
if_kind="$(json_get_raw 'if .properties.policyRule.if.allOf then "allOf" elif .properties.policyRule.if.field then "field" else "unknown" end')"
first_allof_field="$(json_get_raw '.properties.policyRule.if.allOf[0].field // empty')"
top_level_field="$(json_get_raw '.properties.policyRule.if.field // empty')"

if [[ -z "$display_name" ]]; then
	add_error "缺少 properties.displayName"
elif [[ "$display_name" != "$policy_basename" ]]; then
	add_error "檔名與 properties.displayName 不一致：檔名為 $policy_basename，displayName 為 $display_name"
fi

if [[ -z "$description" ]]; then
	add_error "缺少 properties.description"
fi

if [[ "$policy_type" != "Custom" ]]; then
	add_error "properties.policyType 必須為 Custom，目前為 ${policy_type:-<empty>}"
fi

if [[ "$mode" != "Indexed" && "$mode" != "All" ]]; then
	add_error "properties.mode 必須為 Indexed 或 All，目前為 ${mode:-<empty>}"
fi

if [[ -z "$metadata_category" ]]; then
	add_error "缺少 properties.metadata.category"
fi

if [[ -z "$metadata_version" ]]; then
	add_error "缺少 properties.metadata.version"
fi

if ! json_has_value '.properties.policyRule.if'; then
	add_error "缺少 properties.policyRule.if"
fi

if ! json_has_value '.properties.policyRule.then'; then
	add_error "缺少 properties.policyRule.then"
fi

if [[ "$then_effect" == "[parameters('effect')]" && "$effect_parameter_type" != "String" ]]; then
	add_error "policyRule.then.effect 使用 parameters('effect')，但 properties.parameters.effect.type 不是 String"
fi

if [[ "$if_kind" == "allOf" && "$first_allof_field" != "type" ]]; then
	add_warning "建議 policyRule.if.allOf 的第一個條件使用 field=type，目前為 ${first_allof_field:-<empty>}"
fi

if [[ "$if_kind" == "field" && "$top_level_field" != "type" && "$top_level_field" != "location" ]]; then
	add_warning "建議 policyRule.if 優先限定 type，目前第一個 field 為 ${top_level_field:-<empty>}"
fi

if [[ ${#errors[@]} -gt 0 ]]; then
	print_check "FAIL" "$policy_basename 本地驗證失敗"
	for error_message in "${errors[@]}"; do
		print_check "ERROR" "$error_message"
	done
	if (( ${#warnings[@]} > 0 )); then
		for warning_message in "${warnings[@]}"; do
			print_check "WARN" "$warning_message"
		done
	fi
	exit 1
fi

print_check "PASS" "$policy_basename 本地結構驗證通過"
if (( ${#warnings[@]} > 0 )); then
	for warning_message in "${warnings[@]}"; do
		print_check "WARN" "$warning_message"
	done
fi

if [[ "$LOCAL_ONLY" == true ]]; then
	exit 0
fi

if [[ "$AZURE_SMOKE_TEST" != true ]]; then
	exit 0
fi

require_command az
ensure_azure_login

MANAGEMENT_GROUP_ID="$(resolve_management_group_id "$MANAGEMENT_GROUP_ID")"
build_management_group_scope_args "$MANAGEMENT_GROUP_ID"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

smoke_rule_file="$tmp_dir/rule.json"
smoke_params_file="$tmp_dir/params.json"
smoke_metadata_file="$tmp_dir/metadata.json"

jq '.properties.policyRule' "$POLICY_FILE" > "$smoke_rule_file"
jq '.properties.parameters // {}' "$POLICY_FILE" > "$smoke_params_file"
jq '.properties.metadata // {}' "$POLICY_FILE" > "$smoke_metadata_file"

stable_key="$(compute_stable_key "$policy_basename")"
test_policy_name="${NAME_PREFIX}-${stable_key}"

az policy definition create \
	--name "$test_policy_name" \
	--display-name "validation-$display_name" \
	--description "$description" \
	--mode "$mode" \
	--rules "$smoke_rule_file" \
	--params "$smoke_params_file" \
	--metadata "$smoke_metadata_file" \
	"${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" >/dev/null

print_check "PASS" "Azure smoke test 建立成功：$test_policy_name"

if [[ "$KEEP_TEST_POLICY" != true ]]; then
	az policy definition delete \
		--name "$test_policy_name" \
		"${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" >/dev/null
	print_check "PASS" "已刪除測試用 policy definition：$test_policy_name"
fi