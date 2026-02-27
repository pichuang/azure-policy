#!/bin/bash

set -euo pipefail

POLICY_SET_NAME="${POLICY_SET_NAME:-稻草人原則集}"
POLICY_DIR="${POLICY_DIR:-./policies}"
NAME_PREFIX="${NAME_PREFIX:-scarecrow}"
MANAGEMENT_GROUP_ID="${MANAGEMENT_GROUP_ID:-}"
INITIATIVE_CATEGORY="${INITIATIVE_CATEGORY:-Regulatory Compliance}"

for cmd in az jq; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "找不到必要指令：$cmd"
		exit 1
	fi
done

if [[ ! -d "$POLICY_DIR" ]]; then
	echo "找不到原則資料夾：$POLICY_DIR"
	exit 1
fi

if ! az account show >/dev/null 2>&1; then
	echo "尚未登入 Azure，請先執行：az login"
	exit 1
fi

if [[ -z "$MANAGEMENT_GROUP_ID" ]]; then
	MANAGEMENT_GROUP_ID="$(az account show --query tenantId -o tsv)"
fi

scope_args=(--management-group "$MANAGEMENT_GROUP_ID")

if ! az policy set-definition show --name "$POLICY_SET_NAME" "${scope_args[@]}" >/dev/null 2>&1; then
	echo "找不到原則集：$POLICY_SET_NAME"
	echo "請先執行 1-create-dummy-policy.sh 建立原則集，或調整 POLICY_SET_NAME。"
	exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

new_defs_file="$tmp_dir/new-definitions.json"
echo "[]" > "$new_defs_file"

found_any=false

while IFS= read -r -d '' policy_file; do
	found_any=true
	file_name="$(basename "$policy_file" .json)"

	display_name="$(jq -r '.properties.displayName // empty' "$policy_file")"
	if [[ -z "$display_name" || "$display_name" == "null" ]]; then
		display_name="$file_name"
	fi

	description="$(jq -r '.properties.description // empty' "$policy_file")"
	mode="$(jq -r '.properties.mode // "Indexed"' "$policy_file")"

	stable_key="$(printf '%s' "$file_name" | shasum | awk '{print $1}' | cut -c1-12)"
	policy_name="${NAME_PREFIX}-${stable_key}"

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
		"${scope_args[@]}" \
		--query id -o tsv)"

	jq --arg id "$policy_id" '. + [{"policyDefinitionId": $id}]' "$new_defs_file" > "$new_defs_file.tmp"
	mv "$new_defs_file.tmp" "$new_defs_file"

done < <(find "$POLICY_DIR" -maxdepth 1 -type f -name '*.json' -print0)

if [[ "$found_any" == false ]]; then
	echo "在 $POLICY_DIR 找不到任何 .json 原則檔。"
	exit 1
fi

existing_defs_file="$tmp_dir/existing-definitions.json"
merged_defs_file="$tmp_dir/merged-definitions.json"
initiative_metadata_file="$tmp_dir/initiative-metadata.json"

cat <<EOF > "$initiative_metadata_file"
{
	"category": "${INITIATIVE_CATEGORY}"
}
EOF

az policy set-definition show \
	--name "$POLICY_SET_NAME" \
	"${scope_args[@]}" \
	--query "policyDefinitions" \
	-o json > "$existing_defs_file"

jq -s '.[0] + .[1] | unique_by((.policyDefinitionId // "") | ascii_downcase)' \
	"$existing_defs_file" "$new_defs_file" > "$merged_defs_file"

az policy set-definition update \
	--name "$POLICY_SET_NAME" \
	"${scope_args[@]}" \
	--metadata "$initiative_metadata_file" \
	--definitions "$merged_defs_file" >/dev/null

echo "已將 $POLICY_DIR 中所有原則加入（或更新）到原則集：$POLICY_SET_NAME"
