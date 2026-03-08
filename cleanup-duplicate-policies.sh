#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/policy-common.sh
source "$SCRIPT_DIR/utils/policy-common.sh"

MANAGEMENT_GROUP_ID="${MANAGEMENT_GROUP_ID:-}"
POLICY_DIR="${POLICY_DIR:-$SCRIPT_DIR/policies}"
NAME_PREFIX="${NAME_PREFIX:-scarecrow}"
DISPLAY_NAME_FILTER="${DISPLAY_NAME_FILTER:-}"
APPLY_DELETE=false

usage() {
	cat <<'EOF'
用法：
  ./cleanup-duplicate-policies.sh [options]

用途：
  盤點同 displayName 的重複 Azure Policy definitions，標示哪些仍被 initiative 或 assignment 使用，
  並且只刪除未被使用且可安全判定為舊版的 definition。

預設行為：
  只做分析與列出可刪除項目，不會實際刪除。

可選參數：
  --management-group        Management Group 名稱，未提供時預設使用 tenant ID。
  --policy-dir              本地 policy JSON 資料夾，預設為 ./policies。
  --name-prefix             只分析指定前綴的 policy definition name，預設為 scarecrow。
  --display-name            只分析特定 displayName。
  --apply-delete            實際刪除安全可刪的舊 definition。
  -h, --help                顯示說明。

安全刪除條件：
  1. 同 displayName 下存在多個 definitions。
  2. 可推導出首選 definition。
  3. 欲刪除的 definition 未被任何 initiative 使用。
  4. 欲刪除的 definition 未被任何 assignment 直接使用。

範例：
  ./cleanup-duplicate-policies.sh \
    --management-group mg-alz

  ./cleanup-duplicate-policies.sh \
    --management-group mg-alz \
    --display-name "自動為虛擬機器啟用主機端加密 (Encryption at host)"

  ./cleanup-duplicate-policies.sh \
    --management-group mg-alz \
    --apply-delete
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--management-group)
				MANAGEMENT_GROUP_ID="$2"
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
			--display-name)
				DISPLAY_NAME_FILTER="$2"
				shift 2
				;;
			--apply-delete)
				APPLY_DELETE=true
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

print_section() {
	local title="$1"
	printf '\n=== %s ===\n' "$title"
}

delete_definition_and_verify() {
	local definition_name="$1"
	local definition_id="$2"
	local delete_uri="https://management.azure.com${definition_id}?api-version=2023-04-01"
	local attempt=0

	az rest --method delete --url "$delete_uri" >/dev/null

	for attempt in 1 2 3 4 5; do
		if ! az policy definition show --name "$definition_name" "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" >/dev/null 2>&1; then
			return 0
		fi

		sleep 2
	done

	return 1
}

append_json_object() {
	local file_path="$1"
	local object_json="$2"

	jq --argjson obj "$object_json" '. + [$obj]' "$file_path" > "$file_path.tmp"
	mv "$file_path.tmp" "$file_path"
}

build_local_policy_map() {
	local map_file="$1"

	echo '[]' > "$map_file"

	if [[ ! -d "$POLICY_DIR" ]]; then
		return 0
	fi

	while IFS= read -r -d '' policy_file; do
		local file_name=""
		local display_name=""
		local expected_name=""
		local object_json=""

		file_name="$(basename "$policy_file" .json)"
		display_name="$(jq -r '.properties.displayName // empty' "$policy_file")"

		if [[ -z "$display_name" ]]; then
			continue
		fi

		expected_name="${NAME_PREFIX}-$(compute_stable_key "$file_name")"
		object_json="$(jq -cn \
			--arg displayName "$display_name" \
			--arg expectedName "$expected_name" \
			--arg filePath "$policy_file" \
			'{displayName: $displayName, expectedName: $expectedName, filePath: $filePath}')"
		append_json_object "$map_file" "$object_json"
	done < <(find "$POLICY_DIR" -maxdepth 1 -type f -name '*.json' -print0 | sort -z)
}

collect_definition_usage() {
	local definition_name="$1"
	local definition_id="$2"
	local initiatives_file="$3"
	local assignments_file="$4"

	local initiative_names_json=""
	local assignment_names_json=""

	initiative_names_json="$(jq -n \
		--arg id "$definition_id" \
		--arg name "$definition_name" \
		--slurpfile initiatives "$initiatives_file" '
			[
				$initiatives[0][]?
				| select(any((.policyDefinitions // [])[]?; ((.policyDefinitionId // "") == $id) or ((.policyDefinitionReferenceId // "") == $name)))
				| .name
			] | unique
		')"

	assignment_names_json="$(jq -n \
		--arg id "$definition_id" \
		--slurpfile assignments "$assignments_file" '
			[
				$assignments[0][]?
				| select((.policyDefinitionId // "") == $id)
				| .name
			] | unique
		')"

	jq -cn \
		--arg name "$definition_name" \
		--arg id "$definition_id" \
		--argjson initiatives "$initiative_names_json" \
		--argjson assignments "$assignment_names_json" '
			{
				name: $name,
				id: $id,
				initiativeNames: $initiatives,
				assignmentNames: $assignments,
				initiativeCount: ($initiatives | length),
				assignmentCount: ($assignments | length)
			}
		'
}

parse_args "$@"

for cmd in az jq find basename sort; do
	require_command "$cmd"
done

ensure_azure_login

MANAGEMENT_GROUP_ID="$(resolve_management_group_id "$MANAGEMENT_GROUP_ID")"
build_management_group_scope_args "$MANAGEMENT_GROUP_ID"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

local_map_file="$tmp_dir/local-policy-map.json"
build_local_policy_map "$local_map_file"

definitions_file="$tmp_dir/definitions.json"
initiatives_file="$tmp_dir/initiatives.json"
assignments_file="$tmp_dir/assignments.json"
duplicate_groups_file="$tmp_dir/duplicate-groups.json"

az policy definition list "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" -o json > "$definitions_file"
az policy set-definition list "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" -o json > "$initiatives_file"
az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/$MANAGEMENT_GROUP_ID" -o json > "$assignments_file"

jq -n \
		--arg prefix "${NAME_PREFIX}-" \
		--arg displayFilter "$DISPLAY_NAME_FILTER" \
		--slurpfile definitions "$definitions_file" '
			$definitions[0]
			| map(select((.name // "" | startswith($prefix)) and ($displayFilter == "" or (.displayName // "") == $displayFilter)))
			| sort_by(.displayName // "", .name // "")
			| group_by(.displayName)
			| map(select(length > 1))
		' > "$duplicate_groups_file"

if [[ "$(jq 'length' "$duplicate_groups_file")" -eq 0 ]]; then
	print_section "分析結果"
	echo "找不到符合條件的重複 policy definitions。"
	exit 0
fi

overall_group_count=0
overall_deletable_count=0
overall_deleted_count=0

print_section "分析結果"

while IFS= read -r group_json; do
	overall_group_count=$((overall_group_count + 1))
	display_name="$(jq -r '.[0].displayName // "<empty>"' <<<"$group_json")"
	expected_name="$(jq -r --arg displayName "$display_name" 'map(select(.displayName == $displayName))[0].expectedName // empty' "$local_map_file")"

	analysis_file="$tmp_dir/group-analysis-${overall_group_count}.json"
	echo '[]' > "$analysis_file"

	while IFS= read -r definition_json; do
		definition_name="$(jq -r '.name // empty' <<<"$definition_json")"
		definition_id="$(jq -r '.id // empty' <<<"$definition_json")"
		usage_json="$(collect_definition_usage "$definition_name" "$definition_id" "$initiatives_file" "$assignments_file")"
		append_json_object "$analysis_file" "$usage_json"
	done < <(jq -c '.[]' <<<"$group_json")

	preferred_name=""
	preferred_reason=""

	if [[ -n "$expected_name" ]] && jq -e --arg expectedName "$expected_name" 'map(select(.name == $expectedName)) | length == 1' "$analysis_file" >/dev/null 2>&1; then
		preferred_name="$expected_name"
		preferred_reason="符合本地 policy 檔案推導出的預期名稱"
	else
		initiative_backed_name="$(jq -r 'map(select(.initiativeCount > 0)) | if length == 1 then .[0].name else empty end' "$analysis_file")"
		assignment_backed_name="$(jq -r 'map(select((.initiativeCount + .assignmentCount) > 0)) | if length == 1 then .[0].name else empty end' "$analysis_file")"

		if [[ -n "$initiative_backed_name" ]]; then
			preferred_name="$initiative_backed_name"
			preferred_reason="唯一被 initiative 使用的 definition"
		elif [[ -n "$assignment_backed_name" ]]; then
			preferred_name="$assignment_backed_name"
			preferred_reason="唯一被 assignment 或 initiative 使用的 definition"
		fi
	fi

	echo "displayName: $display_name"
	if [[ -n "$preferred_name" ]]; then
		echo "  preferredDefinition: $preferred_name"
		echo "  preferredReason: $preferred_reason"
	else
		echo "  preferredDefinition: <無法安全判定>"
		echo "  preferredReason: 沒有唯一可採用的首選 definition，將不自動刪除任何項目"
	fi

	group_deletable_count=0
	group_deleted_count=0

	while IFS= read -r usage_json; do
		definition_name="$(jq -r '.name' <<<"$usage_json")"
		definition_id="$(jq -r '.id' <<<"$usage_json")"
		initiative_count="$(jq -r '.initiativeCount' <<<"$usage_json")"
		assignment_count="$(jq -r '.assignmentCount' <<<"$usage_json")"
		initiative_names="$(jq -r 'if (.initiativeNames | length) == 0 then "<none>" else (.initiativeNames | join(", ")) end' <<<"$usage_json")"
		assignment_names="$(jq -r 'if (.assignmentNames | length) == 0 then "<none>" else (.assignmentNames | join(", ")) end' <<<"$usage_json")"
		status="保留"
		deletable=false

		if [[ -n "$preferred_name" && "$definition_name" != "$preferred_name" && "$initiative_count" == "0" && "$assignment_count" == "0" ]]; then
			status="可安全刪除"
			deletable=true
			group_deletable_count=$((group_deletable_count + 1))
		fi

		echo "  - name: $definition_name"
		echo "    id: $definition_id"
		echo "    initiativeUsage: $initiative_count ($initiative_names)"
		echo "    assignmentUsage: $assignment_count ($assignment_names)"
		echo "    status: $status"

		if [[ "$APPLY_DELETE" == true && "$deletable" == true ]]; then
			echo "    action: 刪除 definition"
			if delete_definition_and_verify "$definition_name" "$definition_id"; then
				echo "    action: 已刪除"
				group_deleted_count=$((group_deleted_count + 1))
			else
				echo "    action: 刪除驗證失敗，definition 仍然存在"
			fi
		fi
	done < <(jq -c '.[]' "$analysis_file")

	overall_deletable_count=$((overall_deletable_count + group_deletable_count))
	overall_deleted_count=$((overall_deleted_count + group_deleted_count))
	done < <(jq -c '.[]' "$duplicate_groups_file")

print_section "總結"
echo "duplicateDisplayNameGroups: $overall_group_count"
echo "safeDeletableDefinitions: $overall_deletable_count"

if [[ "$APPLY_DELETE" == true ]]; then
	echo "deletedDefinitions: $overall_deleted_count"
else
	echo "deletedDefinitions: 0"
	echo "若要實際刪除，請重新執行並加上 --apply-delete"
fi