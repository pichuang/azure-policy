#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/policy-common.sh
source "$SCRIPT_DIR/utils/policy-common.sh"

POLICY_SET_NAME="${POLICY_SET_NAME:-虛擬資料中心原則}"
DISPLAY_NAME="${DISPLAY_NAME:-$POLICY_SET_NAME}"
DESCRIPTION="${DESCRIPTION:-虛擬資料中心原則，專門進行自動化變更和修復以符合規範}"
POLICY_DIR="${POLICY_DIR:-$SCRIPT_DIR/policies}"
NAME_PREFIX="${NAME_PREFIX:-scarecrow}"
MANAGEMENT_GROUP_ID="${MANAGEMENT_GROUP_ID:-}"
INITIATIVE_CATEGORY="${INITIATIVE_CATEGORY:-Regulatory Compliance}"
VALIDATE_SCRIPT="${VALIDATE_SCRIPT:-$SCRIPT_DIR/validate-policy.sh}"
SKIP_VALIDATION="${SKIP_VALIDATION:-false}"

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
	--skip-validation         跳過單一 policy 本地驗證。
  -h, --help                顯示說明。

也可透過環境變數設定：
	POLICY_SET_NAME, DISPLAY_NAME, DESCRIPTION, POLICY_DIR, NAME_PREFIX, MANAGEMENT_GROUP_ID, INITIATIVE_CATEGORY, SKIP_VALIDATION
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
			--skip-validation)
				SKIP_VALIDATION=true
				shift
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

ensure_initiative_exists() {
	local tmp_dir="$1"
	local dummy_rule_file="$tmp_dir/dummy-policy-rule.json"
	local initiative_defs_file="$tmp_dir/scarecrow-initiative.json"
	local initiative_metadata_file="$tmp_dir/scarecrow-initiative-metadata.json"
	local dummy_policy_id=""

	if az policy set-definition show --name "$POLICY_SET_NAME" "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" >/dev/null 2>&1; then
		echo "原則集已存在，略過 placeholder Initiative 建立：$POLICY_SET_NAME"
		return 0
	fi

	cat <<'EOF' > "$dummy_rule_file"
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

	echo "建立 Dummy Policy..."
	if az policy definition show --name "DummyScarecrowPolicy" "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" >/dev/null 2>&1; then
		dummy_policy_id="$(az policy definition show \
			--name "DummyScarecrowPolicy" \
			"${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" \
			--query id -o tsv)"
	else
		dummy_policy_id="$(az policy definition create \
			--name "DummyScarecrowPolicy" \
			--display-name "Dummy Scarecrow Policy" \
			--description "This is a dummy policy that does nothing, used solely as a placeholder for an Initiative." \
			--mode "All" \
			--rules "$dummy_rule_file" \
			"${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" \
			--query id -o tsv)"
	fi

	cat <<EOF > "$initiative_defs_file"
[
  {
    "policyDefinitionId": "${dummy_policy_id}",
    "policyDefinitionReferenceId": "DummyScarecrowPolicy"
  }
]
EOF

	cat <<EOF > "$initiative_metadata_file"
{
	"category": "${INITIATIVE_CATEGORY}"
}
EOF

	az policy set-definition create \
		--name "$POLICY_SET_NAME" \
		--display-name "$DISPLAY_NAME" \
		--description "$DESCRIPTION" \
		"${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" \
		--metadata "$initiative_metadata_file" \
		--definitions "$initiative_defs_file" >/dev/null

	echo "Dummy policy '$POLICY_SET_NAME' 已成功建立！"
}

update_policies_in_initiative() {
	local tmp_dir="$1"
	local new_defs_file="$tmp_dir/new-definitions.json"
	local existing_defs_file="$tmp_dir/existing-definitions.json"
	local preserved_defs_file="$tmp_dir/preserved-definitions.json"
	local merged_defs_file="$tmp_dir/merged-definitions.json"
	local initiative_metadata_file="$tmp_dir/initiative-metadata.json"
	local found_any=false

	if [[ ! -d "$POLICY_DIR" ]]; then
		echo "找不到原則資料夾：$POLICY_DIR"
		exit 1
	fi

	if ! az policy set-definition show --name "$POLICY_SET_NAME" "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" >/dev/null 2>&1; then
		echo "找不到原則集：$POLICY_SET_NAME"
		echo "請先建立原則集，或調整 POLICY_SET_NAME。"
		exit 1
	fi

	echo '[]' > "$new_defs_file"

	while IFS= read -r -d '' policy_file; do
		local file_name=""
		local display_name=""
		local description=""
		local mode=""
		local stable_key=""
		local policy_name=""
		local policy_definition_reference_id=""
		local rule_file=""
		local params_file=""
		local metadata_file=""
		local policy_id=""

		found_any=true
		file_name="$(basename "$policy_file" .json)"

		if [[ "$SKIP_VALIDATION" != "true" ]]; then
			"$VALIDATE_SCRIPT" --policy-file "$policy_file" --local-only >/dev/null
		fi

		display_name="$(jq -r '.properties.displayName // empty' "$policy_file")"
		if [[ -z "$display_name" || "$display_name" == "null" ]]; then
			display_name="$file_name"
		fi

		description="$(jq -r '.properties.description // empty' "$policy_file")"
		mode="$(jq -r '.properties.mode // "Indexed"' "$policy_file")"
		stable_key="$(compute_stable_key "$file_name")"
		policy_name="${NAME_PREFIX}-${stable_key}"
		policy_definition_reference_id="$policy_name"
		rule_file="$tmp_dir/${policy_name}-rule.json"
		params_file="$tmp_dir/${policy_name}-params.json"
		metadata_file="$tmp_dir/${policy_name}-metadata.json"

		jq '.properties.policyRule' "$policy_file" > "$rule_file"
		jq '.properties.parameters // {}' "$policy_file" > "$params_file"
		jq '.properties.metadata // {}' "$policy_file" > "$metadata_file"

		echo "新增原則：$display_name"

		policy_id="$(az policy definition create \
			--name "$policy_name" \
			--display-name "$display_name" \
			--description "$description" \
			--mode "$mode" \
			--rules "$rule_file" \
			--params "$params_file" \
			--metadata "$metadata_file" \
			"${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" \
			--query id -o tsv)"

		jq \
			--arg id "$policy_id" \
			--arg referenceId "$policy_definition_reference_id" \
			'. + [{"policyDefinitionId": $id, "policyDefinitionReferenceId": $referenceId}]' \
			"$new_defs_file" > "$new_defs_file.tmp"
		mv "$new_defs_file.tmp" "$new_defs_file"
	done < <(find "$POLICY_DIR" -maxdepth 1 -type f -name '*.json' -print0 | sort -z)

	if [[ "$found_any" == false ]]; then
		echo "在 $POLICY_DIR 找不到任何 .json 原則檔。"
		exit 1
	fi

	cat <<EOF > "$initiative_metadata_file"
{
	"category": "${INITIATIVE_CATEGORY}"
}
EOF

	az policy set-definition show \
		--name "$POLICY_SET_NAME" \
		"${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" \
		--query "policyDefinitions" \
		-o json > "$existing_defs_file"

	jq --arg prefix "/policyDefinitions/${NAME_PREFIX}-" '
		map(select(((.policyDefinitionId // "") | ascii_downcase | contains(($prefix | ascii_downcase))) | not))
	' "$existing_defs_file" > "$preserved_defs_file"

	jq -s '.[0] + .[1] | unique_by((.policyDefinitionId // "") | ascii_downcase)' \
		"$preserved_defs_file" "$new_defs_file" > "$merged_defs_file"

	az policy set-definition update \
		--name "$POLICY_SET_NAME" \
		"${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" \
		--metadata "$initiative_metadata_file" \
		--definitions "$merged_defs_file" >/dev/null

	echo "已將 $POLICY_DIR 中所有原則加入（或更新）到原則集：$POLICY_SET_NAME"
}

parse_args "$@"

for cmd in az jq find sort; do
	require_command "$cmd"
done

ensure_azure_login
MANAGEMENT_GROUP_ID="$(resolve_management_group_id "$MANAGEMENT_GROUP_ID")"
build_management_group_scope_args "$MANAGEMENT_GROUP_ID"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

ensure_initiative_exists "$tmp_dir"
update_policies_in_initiative "$tmp_dir"