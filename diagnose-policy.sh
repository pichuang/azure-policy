#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/policy-common.sh
source "$SCRIPT_DIR/utils/policy-common.sh"

POLICY_FILE=""
POLICY_SET_NAME="${POLICY_SET_NAME:-虛擬資料中心原則}"
NAME_PREFIX="${NAME_PREFIX:-scarecrow}"
MANAGEMENT_GROUP_ID="${MANAGEMENT_GROUP_ID:-}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
TARGET_RESOURCE_ID="${TARGET_RESOURCE_ID:-}"
ASSIGNMENT="${ASSIGNMENT:-}"
TOP_RESULTS="${TOP_RESULTS:-100}"
RESOURCE_DISCOVERY_MODE="${RESOURCE_DISCOVERY_MODE:-ReEvaluateCompliance}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
POLL_TIMEOUT="${POLL_TIMEOUT:-1800}"
TRIGGER_SCAN=false
RUN_REMEDIATION=false
SHOW_RAW_JSON=false
SKIP_LOCAL_VALIDATION=false

declare -a EXPLICIT_SCOPE_ARGS=()
declare -a ASSIGNMENT_SCOPE_ARGS=()
declare -a LOCATION_FILTERS=()

usage() {
	cat <<'EOF'
用法：
  ./diagnose-policy.sh --policy-file <path> [options]

用途：
	將單一 Azure Policy 的排查流程自動化，依序檢查本地 JSON、Azure policy definition、
	initiative 內的 policyDefinitionReferenceId、assignment、compliance state，並可選擇直接觸發 remediation。

前置條件：
	1. 已安裝 Azure CLI 與 jq。
	2. 已完成 az login。
	3. 這份 policy 已透過 deploy-policies.sh 部署到 Azure。
	4. 若要檢查 assignment 或 remediation，必須提供 --assignment。

必要參數：
  --policy-file             要排查的單一 policy JSON 檔案。

可選參數：
  --policy-set-name         Initiative 名稱，預設為「虛擬資料中心原則」。
  --name-prefix             自訂 policy definition name 前綴，預設為 scarecrow。
  --assignment              要排查的 policy assignment 名稱或完整 resource ID。
  --management-group        Management Group 名稱。
  --subscription            Subscription ID 或名稱。
  --resource-group          Resource Group 名稱。
  --resource                目標資源的 resource ID，也可用來縮小 policy state 排查範圍。
  --top-results             讀取 policy states 時的最大筆數，預設 100。
  --trigger-scan            先觸發一次 policy state 重新評估。
	--run-remediation         若 assignment 與 referenceId 都可判定，直接在診斷流程末端執行 remediation。
	--location-filter         remediation 時僅修復指定 Azure 區域，可重複帶入多次。
	--resource-discovery-mode remediation 資源探索模式，可為 ExistingNonCompliant 或 ReEvaluateCompliance，預設 ReEvaluateCompliance。
	--poll-interval           remediation 輪詢秒數，預設 10。
	--poll-timeout            remediation 最長等待秒數，預設 1800。
  --show-raw-json           額外輸出 definition、assignment、policy state 的原始 JSON。
	--skip-local-validation   跳過 validate-policy.sh 本地驗證。
  -h, --help                顯示說明。

建議使用順序：
	1. 先只帶 --policy-file 與 scope，確認 definition 與 initiative 是否存在。
	2. 再加上 --assignment，確認 assignment effect、scope 與 compliance state。
	3. 若 policy 是 Modify 或 deployIfNotExists，再視情況加上 --run-remediation。

常見情境範例：
	1. 最小排查，只看 definition 與 initiative：
		 ./diagnose-policy.sh \
			 --policy-file "./policies/自動為 Storage Account 停用匿名存取.json" \
			 --management-group contoso-platform

	2. 連 assignment 一起查：
		 ./diagnose-policy.sh \
			 --policy-file "./policies/自動為 Storage Account 停用匿名存取.json" \
			 --management-group contoso-platform \
			 --assignment asg-storage-baseline

	3. 只針對單一資源看 compliance：
		 ./diagnose-policy.sh \
			 --policy-file "./policies/自動為 Storage Account 停用匿名存取.json" \
			 --management-group contoso-platform \
			 --assignment asg-storage-baseline \
			 --resource "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>"

	4. 先觸發重新評估再查：
		 ./diagnose-policy.sh \
			 --policy-file "./policies/自動為 Storage Account 停用匿名存取.json" \
			 --management-group contoso-platform \
			 --assignment asg-storage-baseline \
			 --trigger-scan

	5. 直接接續 remediation：
		 ./diagnose-policy.sh \
			 --policy-file "./policies/自動為 Storage Account 停用匿名存取.json" \
			 --management-group contoso-platform \
			 --assignment asg-storage-baseline \
			 --run-remediation

完整範例：
  ./diagnose-policy.sh \
    --policy-file "./policies/自動為 Storage Account 停用匿名存取.json" \
    --management-group contoso-platform \
    --assignment asg-storage-baseline \
    --resource "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>" \
    --trigger-scan

輸出判讀：
	- definitionFound=false：代表 policy definition 尚未部署成功，先重跑 deploy-policies.sh。
	- referenceFoundInInitiative=false：代表 initiative 內沒有這條 policy，先重跑 deploy-policies.sh。
	- assignmentFound=false：代表 assignment 不存在、scope 不對，或 assignment 名稱輸入錯誤。
	- effectHint 顯示 Disabled：代表 assignment 已把 policy 關閉，不會作動。
	- matchingNonCompliantStates > 0：代表條件有命中，但未必已修正完成。
	- matchingPolicyStates = 0：代表尚未評估完成、scope 不對，或這條 policy 沒命中資源。

注意事項：
	- 這支腳本主要用於 Management Group 範圍的部署模型；若 assignment 在 Subscription 或 Resource Group，
		請搭配 --subscription 或 --resource-group 指定更精確 scope。
	- 若 policy 類型是 Modify 或 deployIfNotExists，僅看到 NonCompliant 並不代表失敗，通常還需要 remediation。
	- 若搭配 --run-remediation，這支腳本會直接建立 remediation、輪詢狀態並輸出 deployment 摘要。
	- --show-raw-json 會輸出較多原始 JSON，適合進一步分析 CLI 回傳內容。
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--policy-file)
				POLICY_FILE="$2"
				shift 2
				;;
			--policy-set-name)
				POLICY_SET_NAME="$2"
				shift 2
				;;
			--name-prefix)
				NAME_PREFIX="$2"
				shift 2
				;;
			--assignment)
				ASSIGNMENT="$2"
				shift 2
				;;
			--management-group)
				MANAGEMENT_GROUP_ID="$2"
				shift 2
				;;
			--subscription)
				SUBSCRIPTION_ID="$2"
				shift 2
				;;
			--resource-group)
				RESOURCE_GROUP="$2"
				shift 2
				;;
			--resource)
				TARGET_RESOURCE_ID="$2"
				shift 2
				;;
			--top-results)
				TOP_RESULTS="$2"
				shift 2
				;;
			--location-filter)
				LOCATION_FILTERS+=("$2")
				shift 2
				;;
			--resource-discovery-mode)
				RESOURCE_DISCOVERY_MODE="$2"
				shift 2
				;;
			--poll-interval)
				POLL_INTERVAL="$2"
				shift 2
				;;
			--poll-timeout)
				POLL_TIMEOUT="$2"
				shift 2
				;;
			--trigger-scan)
				TRIGGER_SCAN=true
				shift
				;;
			--run-remediation)
				RUN_REMEDIATION=true
				shift
				;;
			--show-raw-json)
				SHOW_RAW_JSON=true
				shift
				;;
			--skip-local-validation)
				SKIP_LOCAL_VALIDATION=true
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

print_info() {
	local key="$1"
	local value="$2"
	printf '%s: %s\n' "$key" "$value"
}

sanitize_name() {
	local input="$1"

	printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' | cut -c1-40
}

is_assignment_id() {
	local input="$1"

	[[ "$input" == */providers/Microsoft.Authorization/policyAssignments/* ]]
}

extract_assignment_name() {
	local input="$1"

	if is_assignment_id "$input"; then
		printf '%s\n' "${input##*/}"
	else
		printf '%s\n' "$input"
	fi
}

build_explicit_scope_args() {
	EXPLICIT_SCOPE_ARGS=()

	if [[ -n "$SUBSCRIPTION_ID" ]]; then
		EXPLICIT_SCOPE_ARGS+=(--subscription "$SUBSCRIPTION_ID")
	fi

	if [[ -n "$MANAGEMENT_GROUP_ID" ]]; then
		EXPLICIT_SCOPE_ARGS+=(--management-group "$MANAGEMENT_GROUP_ID")
	elif [[ -n "$RESOURCE_GROUP" ]]; then
		EXPLICIT_SCOPE_ARGS+=(--resource-group "$RESOURCE_GROUP")
	elif [[ -n "$TARGET_RESOURCE_ID" ]]; then
		EXPLICIT_SCOPE_ARGS+=(--resource "$TARGET_RESOURCE_ID")
	fi
}

infer_scope_args_from_assignment_id() {
	local assignment_id="$1"
	local scope_base="${assignment_id%/providers/Microsoft.Authorization/policyAssignments/*}"
	local subscription_from_id=""

	ASSIGNMENT_SCOPE_ARGS=()

	if [[ "$scope_base" == /providers/Microsoft.Management/managementGroups/* ]]; then
		ASSIGNMENT_SCOPE_ARGS+=(--management-group "${scope_base##*/}")
		return 0
	fi

	if [[ "$scope_base" == /subscriptions/* ]]; then
		subscription_from_id="$(printf '%s\n' "$scope_base" | cut -d'/' -f3)"
		if [[ -n "$subscription_from_id" ]]; then
			ASSIGNMENT_SCOPE_ARGS+=(--subscription "$subscription_from_id")
		fi

		if [[ "$scope_base" == /subscriptions/*/resourceGroups/*/providers/* ]]; then
			ASSIGNMENT_SCOPE_ARGS+=(--resource "$scope_base")
		elif [[ "$scope_base" == /subscriptions/*/resourceGroups/* ]]; then
			ASSIGNMENT_SCOPE_ARGS+=(--resource-group "$(printf '%s\n' "$scope_base" | cut -d'/' -f5)")
		fi
	fi
}

extract_summary_metric() {
	local json="$1"
	local key="$2"

	jq -r --arg key "$key" '(.value[0].results? // .results? // {})[$key] // "n/a"' <<<"$json"
}

print_summary_metrics() {
	local json="$1"

	print_info "nonCompliantResources" "$(extract_summary_metric "$json" "nonCompliantResources")"
	print_info "nonCompliantPolicies" "$(extract_summary_metric "$json" "nonCompliantPolicies")"
	print_info "compliantResources" "$(extract_summary_metric "$json" "compliantResources")"
	print_info "compliantPolicies" "$(extract_summary_metric "$json" "compliantPolicies")"
}

print_policy_state_summary() {
	local label="$1"
	local json="$2"

	echo "$label"
	echo "  nonCompliantResources: $(extract_summary_metric "$json" "nonCompliantResources")"
	echo "  nonCompliantPolicies: $(extract_summary_metric "$json" "nonCompliantPolicies")"
	echo "  compliantResources: $(extract_summary_metric "$json" "compliantResources")"
	echo "  compliantPolicies: $(extract_summary_metric "$json" "compliantPolicies")"
}

print_remediation_summary() {
	local json="$1"

	echo "  remediationName: $(jq -r '.name // "n/a"' <<<"$json")"
	echo "  provisioningState: $(jq -r '.provisioningState // .properties.provisioningState // "n/a"' <<<"$json")"
	echo "  policyAssignmentId: $(jq -r '.policyAssignmentId // .properties.policyAssignmentId // "n/a"' <<<"$json")"
	echo "  policyDefinitionReferenceId: $(jq -r '.policyDefinitionReferenceId // .properties.policyDefinitionReferenceId // "n/a"' <<<"$json")"
	echo "  createdOn: $(jq -r '.createdOn // .properties.createdOn // "n/a"' <<<"$json")"
	echo "  lastUpdatedOn: $(jq -r '.lastUpdatedOn // .properties.lastUpdatedOn // "n/a"' <<<"$json")"
}

print_deployment_summary() {
	local json="$1"
	local count=""
	local rows=""

	count="$(jq -r 'if type == "array" then length elif .value then (.value | length) else 0 end' <<<"$json")"
	echo "  remediationDeployments: $count"

	rows="$(jq -r '
		def items:
			if type == "array" then .
			elif .value then .value
			else []
			end;
		items[]? | [
			(.name // .deploymentName // .deploymentId // "n/a"),
			(.resourceLocation // .location // "n/a"),
			(.provisioningState // .deploymentStatus // .status // "n/a")
		] | @tsv
	' <<<"$json")"

	if [[ -n "$rows" ]]; then
		echo "  deploymentDetails:"
		while IFS=$'\t' read -r deployment_name deployment_location deployment_state; do
			echo "    - name=$deployment_name, location=$deployment_location, state=$deployment_state"
		done <<<"$rows"
	fi
}

run_remediation_for_assignment() {
	local assignment="$1"
	local definition_reference_id="$2"
	local assignment_name_local=""
	local remediation_name=""
	local before_summary_json=""
	local create_output=""
	local create_status=0
	local remediation_json=""
	local start_epoch=""
	local final_state=""
	local elapsed=""
	local deployments_json=""
	local after_summary_json=""
	local -a current_scope_args=()
	local -a create_args=()

	assignment_name_local="$(extract_assignment_name "$assignment")"
	remediation_name="force-$(sanitize_name "$assignment_name_local")-$(date +%Y%m%d%H%M%S)"
	current_scope_args=("${ASSIGNMENT_SCOPE_ARGS[@]}")

	echo "remediationScopeArgs: ${current_scope_args[*]:-<subscription 預設 scope>}"
	before_summary_json="$(az policy state summarize "${current_scope_args[@]}" -a "$assignment_name_local" -o json)"
	print_policy_state_summary "建立 remediation 前的合規摘要：" "$before_summary_json"

	create_args=(policy remediation create "${current_scope_args[@]}" --name "$remediation_name" --policy-assignment "$assignment" --resource-discovery-mode "$RESOURCE_DISCOVERY_MODE" -o json)

	if [[ -n "$definition_reference_id" ]]; then
		create_args+=(--definition-reference-id "$definition_reference_id")
	fi

	if [[ ${#LOCATION_FILTERS[@]} -gt 0 ]]; then
		create_args+=(--location-filters "${LOCATION_FILTERS[@]}")
	fi

	set +e
	create_output="$(az "${create_args[@]}" 2>&1)"
	create_status=$?
	set -e

	if [[ $create_status -ne 0 ]]; then
		echo "建立 remediation 失敗：$assignment_name_local"
		echo "$create_output"
		return 1
	fi

	remediation_json="$create_output"
	echo "已建立 remediation。"
	print_remediation_summary "$remediation_json"

	start_epoch="$(date +%s)"
	while true; do
		remediation_json="$(az policy remediation show "${current_scope_args[@]}" --name "$remediation_name" -o json)"
		final_state="$(jq -r '.provisioningState // .properties.provisioningState // "Unknown"' <<<"$remediation_json")"
		elapsed="$(( $(date +%s) - start_epoch ))"

		echo "  等待 remediation 狀態中: provisioningState=$final_state, elapsed=${elapsed}s"

		case "$final_state" in
			Succeeded|Failed|Canceled|Cancelled)
				break
				;;
		esac

		if (( elapsed >= POLL_TIMEOUT )); then
			echo "  等待逾時，已超過 ${POLL_TIMEOUT}s。"
			return 1
		fi

		sleep "$POLL_INTERVAL"
	done

	echo "最終 remediation 狀態："
	print_remediation_summary "$remediation_json"

	deployments_json="$(az policy remediation deployment list "${current_scope_args[@]}" --name "$remediation_name" -o json)"
	echo "deployment 摘要："
	print_deployment_summary "$deployments_json"

	after_summary_json="$(az policy state summarize "${current_scope_args[@]}" -a "$assignment_name_local" -o json)"
	print_policy_state_summary "建立 remediation 後的合規摘要：" "$after_summary_json"

	if [[ "$SHOW_RAW_JSON" == true ]]; then
		echo "remediation JSON："
		echo "$remediation_json" | jq .
		echo "deployment JSON："
		echo "$deployments_json" | jq .
	fi

	if [[ "$final_state" != "Succeeded" ]]; then
		return 1
	fi

	return 0
}

parse_args "$@"

for cmd in az jq basename cut; do
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

if [[ -n "$MANAGEMENT_GROUP_ID" && -n "$RESOURCE_GROUP" ]]; then
	echo "--management-group 與 --resource-group 不能同時指定"
	exit 1
fi

if [[ -n "$MANAGEMENT_GROUP_ID" && -n "$TARGET_RESOURCE_ID" ]]; then
	echo "--management-group 與 --resource 不能同時指定"
	exit 1
fi

if [[ -n "$RESOURCE_GROUP" && -n "$TARGET_RESOURCE_ID" ]]; then
	echo "--resource-group 與 --resource 不能同時指定"
	exit 1
fi

if [[ "$RESOURCE_DISCOVERY_MODE" != "ExistingNonCompliant" && "$RESOURCE_DISCOVERY_MODE" != "ReEvaluateCompliance" ]]; then
	echo "--resource-discovery-mode 只能是 ExistingNonCompliant 或 ReEvaluateCompliance"
	exit 1
fi

if [[ "$SKIP_LOCAL_VALIDATION" != true ]]; then
	"$SCRIPT_DIR/validate-policy.sh" --policy-file "$POLICY_FILE" --local-only
fi

ensure_azure_login

policy_basename="$(basename "$POLICY_FILE" .json)"
display_name="$(jq -r '.properties.displayName // empty' "$POLICY_FILE")"
description="$(jq -r '.properties.description // empty' "$POLICY_FILE")"
default_effect="$(jq -r '.properties.parameters.effect.defaultValue // .properties.policyRule.then.effect // empty' "$POLICY_FILE")"
allowed_effects="$(jq -r '(.properties.parameters.effect.allowedValues // []) | join(", ")' "$POLICY_FILE")"
expected_policy_name="${NAME_PREFIX}-$(compute_stable_key "$policy_basename")"

if [[ -z "$MANAGEMENT_GROUP_ID" ]]; then
	MANAGEMENT_GROUP_ID="$(resolve_management_group_id "$MANAGEMENT_GROUP_ID")"
fi

build_management_group_scope_args "$MANAGEMENT_GROUP_ID"
build_explicit_scope_args

print_section "本地 Policy 資訊"
print_info "policyFile" "$POLICY_FILE"
print_info "displayName" "$display_name"
print_info "description" "$description"
print_info "defaultEffect" "$default_effect"
print_info "allowedEffects" "${allowed_effects:-<none>}"
print_info "expectedPolicyName" "$expected_policy_name"
print_info "policySetName" "$POLICY_SET_NAME"
print_info "managementGroup" "$MANAGEMENT_GROUP_ID"

print_section "Definition 檢查"
definition_found=true
definition_resolved_from="show-by-name"
set +e
definition_json="$(az policy definition show --name "$expected_policy_name" "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" -o json 2>&1)"
definition_status=$?
set -e

if [[ $definition_status -ne 0 ]]; then
	echo "直接以名稱查詢 definition 失敗，改用 fallback 搜尋：$expected_policy_name"
	candidate_json="$(az policy definition list "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" --query "[?displayName=='$display_name'].[name,id,displayName]" -o json)"
	if [[ "$(jq 'length' <<<"$candidate_json")" -gt 0 ]]; then
		echo "找到同 displayName 的候選 definition："
		jq -r '.[] | "- name=\(.[0]), id=\(.[1])"' <<<"$candidate_json"

		resolved_candidate_json="$(jq --arg expectedName "$expected_policy_name" '
			map(select(.[0] == $expectedName)) | if length == 1 then .[0] else empty end
		' <<<"$candidate_json")"

		if [[ -n "$resolved_candidate_json" ]]; then
			definition_found=true
			definition_resolved_from="list-by-displayName-fallback"
			definition_id="$(jq -r '.[1]' <<<"$resolved_candidate_json")"
			print_info "definitionId" "$definition_id"
			print_info "definitionName" "$(jq -r '.[0]' <<<"$resolved_candidate_json")"
			print_info "definitionResolvedFrom" "$definition_resolved_from"
		else
			definition_found=false
			definition_id=""
		fi
	else
		definition_found=false
		definition_id=""
	fi
else
	definition_id="$(jq -r '.id // empty' <<<"$definition_json")"
	print_info "definitionId" "$definition_id"
	print_info "definitionResolvedFrom" "$definition_resolved_from"
	print_info "definitionMode" "$(jq -r '.mode // empty' <<<"$definition_json")"
	print_info "definitionDisplayName" "$(jq -r '.displayName // empty' <<<"$definition_json")"
fi

if [[ "$SHOW_RAW_JSON" == true && "$definition_found" == true ]]; then
	echo "$definition_json" | jq .
fi

print_section "Initiative 檢查"
initiative_found=true
reference_found=false
initiative_resolved_from="show-by-name"
set +e
initiative_json="$(az policy set-definition show --name "$POLICY_SET_NAME" "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" -o json 2>&1)"
initiative_status=$?
set -e

if [[ $initiative_status -ne 0 ]]; then
	initiative_found=false
	echo "直接以名稱查詢 initiative 失敗，改用候選 initiative 搜尋：$POLICY_SET_NAME"
	echo "請優先檢查 initiative 是否建立在 management group '$MANAGEMENT_GROUP_ID'，或名稱是否與部署時使用的 POLICY_SET_NAME 一致。"
	initiative_candidates_json="$(az policy set-definition list "${MANAGEMENT_GROUP_SCOPE_ARGS[@]}" -o json)"
	matching_initiatives_json="$(jq \
		--arg expectedName "$POLICY_SET_NAME" \
		--arg expectedRef "$expected_policy_name" \
		--arg definitionId "$definition_id" '
			map(select(
				(.name == $expectedName) or
				(.displayName == $expectedName) or
				(any(.policyDefinitions[]?; (.policyDefinitionReferenceId // "") == $expectedRef)) or
				($definitionId != "" and any(.policyDefinitions[]?; (.policyDefinitionId // "") == $definitionId))
			))
		' <<<"$initiative_candidates_json")"

	if [[ "$(jq 'length' <<<"$matching_initiatives_json")" -gt 0 ]]; then
		echo "找到可能相關的 initiative 候選："
		jq -r --arg expectedRef "$expected_policy_name" --arg definitionId "$definition_id" '
			.[] | [
				"- name=" + (.name // "n/a"),
				"displayName=" + (.displayName // "n/a"),
				"containsReferenceId=" + (if any(.policyDefinitions[]?; (.policyDefinitionReferenceId // "") == $expectedRef) then "true" else "false" end),
				"containsDefinitionId=" + (if $definitionId != "" and any(.policyDefinitions[]?; (.policyDefinitionId // "") == $definitionId) then "true" else "false" end)
			] | join(", ")
		' <<<"$matching_initiatives_json"

		preferred_initiative_json="$(jq \
			--arg expectedName "$POLICY_SET_NAME" '
				map(select((.name == $expectedName) or (.displayName == $expectedName)))
				| if length == 1 then .[0] else empty end
			' <<<"$matching_initiatives_json")"

		if [[ -n "$preferred_initiative_json" ]]; then
			initiative_found=true
			initiative_resolved_from="list-fallback-exact-name-match"
			initiative_json="$preferred_initiative_json"
			resolved_initiative_name="$(jq -r '.name // empty' <<<"$initiative_json")"
			resolved_initiative_display_name="$(jq -r '.displayName // empty' <<<"$initiative_json")"
			echo "已自動採用精準名稱命中的 initiative 繼續診斷。"
			print_info "resolvedInitiativeName" "$resolved_initiative_name"
			print_info "resolvedInitiativeDisplayName" "$resolved_initiative_display_name"
			print_info "initiativeResolvedFrom" "$initiative_resolved_from"
		elif [[ "$(jq 'length' <<<"$matching_initiatives_json")" -eq 1 ]]; then
			initiative_found=true
			initiative_resolved_from="list-fallback-unique-candidate"
			initiative_json="$(jq '.[0]' <<<"$matching_initiatives_json")"
			resolved_initiative_name="$(jq -r '.name // empty' <<<"$initiative_json")"
			resolved_initiative_display_name="$(jq -r '.displayName // empty' <<<"$initiative_json")"
			echo "已自動採用唯一候選 initiative 繼續診斷。"
			print_info "resolvedInitiativeName" "$resolved_initiative_name"
			print_info "resolvedInitiativeDisplayName" "$resolved_initiative_display_name"
			print_info "initiativeResolvedFrom" "$initiative_resolved_from"
		fi
	else
		echo "在目前 management group scope 下找不到明顯相關的 initiative 候選。"
	fi

	if [[ "$initiative_found" != true ]]; then
		initiative_json=""
	fi
fi

if [[ "$initiative_found" == true ]]; then
	if [[ "$initiative_resolved_from" == "show-by-name" ]]; then
		print_info "initiativeResolvedFrom" "$initiative_resolved_from"
	fi
	reference_entry="$(jq -c --arg ref "$expected_policy_name" '.policyDefinitions[]? | select(.policyDefinitionReferenceId == $ref)' <<<"$initiative_json")"
	if [[ -n "$reference_entry" ]]; then
		reference_found=true
		print_info "policyDefinitionReferenceId" "$expected_policy_name"
		print_info "initiativeContainsPolicy" "true"
	else
		print_info "policyDefinitionReferenceId" "$expected_policy_name"
		print_info "initiativeContainsPolicy" "false"
	fi
fi

if [[ "$SHOW_RAW_JSON" == true && "$initiative_found" == true ]]; then
	echo "$initiative_json" | jq .
fi

assignment_name=""
assignment_found=false
assignment_effect=""
assignment_scope_source="未指定 assignment"

if [[ -n "$ASSIGNMENT" ]]; then
	print_section "Assignment 檢查"
	assignment_name="$(extract_assignment_name "$ASSIGNMENT")"
	ASSIGNMENT_SCOPE_ARGS=("${EXPLICIT_SCOPE_ARGS[@]}")

	if [[ ${#ASSIGNMENT_SCOPE_ARGS[@]} -eq 0 ]]; then
		if is_assignment_id "$ASSIGNMENT"; then
			infer_scope_args_from_assignment_id "$ASSIGNMENT"
			assignment_scope_source="由 assignment resource ID 推導"
		else
			ASSIGNMENT_SCOPE_ARGS=(--management-group "$MANAGEMENT_GROUP_ID")
			assignment_scope_source="預設使用 management group"
		fi
	else
		assignment_scope_source="使用命令列指定 scope"
	fi

	print_info "assignmentName" "$assignment_name"
	print_info "assignmentScopeSource" "$assignment_scope_source"
	print_info "assignmentScopeArgs" "${ASSIGNMENT_SCOPE_ARGS[*]:-<subscription 預設 scope>}"

	set +e
	assignment_json="$(az policy assignment show "${ASSIGNMENT_SCOPE_ARGS[@]}" --name "$assignment_name" -o json 2>&1)"
	assignment_status=$?
	set -e

	if [[ $assignment_status -ne 0 ]]; then
		echo "找不到 assignment：$assignment_name"
		echo "$assignment_json"
	else
		assignment_found=true
		assignment_effect="$(jq -r '.parameters.effect.value // empty' <<<"$assignment_json")"
		print_info "assignmentDefinitionId" "$(jq -r '.policyDefinitionId // empty' <<<"$assignment_json")"
		print_info "assignmentScope" "$(jq -r '.scope // empty' <<<"$assignment_json")"
		print_info "assignmentEnforcementMode" "$(jq -r '.enforcementMode // empty' <<<"$assignment_json")"
		print_info "assignmentEffect" "${assignment_effect:-<not-set>}"
		print_info "assignmentIdentityType" "$(jq -r '.identity.type // "<none>"' <<<"$assignment_json")"
		print_info "notScopesCount" "$(jq -r '(.notScopes // []) | length' <<<"$assignment_json")"
	fi

	if [[ "$SHOW_RAW_JSON" == true && "$assignment_found" == true ]]; then
		echo "$assignment_json" | jq .
	fi

	if [[ "$TRIGGER_SCAN" == true && "$assignment_found" == true ]]; then
		print_section "Trigger Scan"
		set +e
		trigger_output="$(az policy state trigger-scan "${ASSIGNMENT_SCOPE_ARGS[@]}" 2>&1)"
		trigger_status=$?
		set -e

		if [[ $trigger_status -ne 0 ]]; then
			echo "觸發 policy scan 失敗："
			echo "$trigger_output"
		else
			echo "已觸發 policy state 重新評估。"
		fi
	fi

	if [[ "$assignment_found" == true ]]; then
		print_section "Compliance 檢查"
		summary_json="$(az policy state summarize "${ASSIGNMENT_SCOPE_ARGS[@]}" -a "$assignment_name" -o json)"
		print_summary_metrics "$summary_json"

		states_json="$(az policy state list "${ASSIGNMENT_SCOPE_ARGS[@]}" -a "$assignment_name" --top "$TOP_RESULTS" -o json)"
		relevant_states_json="$(jq --arg ref "$expected_policy_name" --arg resourceId "$TARGET_RESOURCE_ID" '
			map(select(((.policyDefinitionReferenceId // .policyDefinitionName // "") == $ref) and ($resourceId == "" or (.resourceId // "") == $resourceId)))
		' <<<"$states_json")"
		noncompliant_count="$(jq '[.[] | select(.complianceState == "NonCompliant")] | length' <<<"$relevant_states_json")"
		compliant_count="$(jq '[.[] | select(.complianceState == "Compliant")] | length' <<<"$relevant_states_json")"
		print_info "matchingPolicyStates" "$(jq 'length' <<<"$relevant_states_json")"
		print_info "matchingNonCompliantStates" "$noncompliant_count"
		print_info "matchingCompliantStates" "$compliant_count"

		if [[ "$(jq 'length' <<<"$relevant_states_json")" -gt 0 ]]; then
			echo "相關 policy states 範例："
			jq -r '.[:10][] | "- complianceState=\(.complianceState // "n/a"), resourceId=\(.resourceId // "n/a"), timestamp=\(.timestamp // "n/a")"' <<<"$relevant_states_json"
		else
			echo "查不到此 policyDefinitionReferenceId 的 policy state。可能是 assignment scope 不對、尚未完成評估，或 assignment 並非 initiative 形式。"
		fi

		if [[ "$SHOW_RAW_JSON" == true ]]; then
			echo "$summary_json" | jq .
			echo "$relevant_states_json" | jq .
		fi
	fi

	if [[ "$RUN_REMEDIATION" == true ]]; then
		print_section "Remediation"
		if [[ "$assignment_found" != true ]]; then
			echo "assignment 不存在，無法執行 remediation。"
		elif [[ "$reference_found" != true ]]; then
			echo "initiative 內找不到 policyDefinitionReferenceId=$expected_policy_name，無法安全執行 remediation。"
		else
			run_remediation_for_assignment "$ASSIGNMENT" "$expected_policy_name"
		fi
	fi
fi

print_section "診斷結論"
print_info "definitionFound" "$definition_found"
print_info "initiativeFound" "$initiative_found"
print_info "referenceFoundInInitiative" "$reference_found"
print_info "assignmentChecked" "$( [[ -n "$ASSIGNMENT" ]] && echo true || echo false )"
print_info "assignmentFound" "$assignment_found"

if [[ -n "$ASSIGNMENT" && "$assignment_found" == true ]]; then
	if [[ -z "$assignment_effect" ]]; then
		print_info "effectHint" "assignment 未明確覆寫 effect，將使用 policy 預設值 ${default_effect:-<unknown>}"
	elif [[ "$assignment_effect" == "Disabled" ]]; then
		print_info "effectHint" "assignment 已將 effect 設為 Disabled，policy 不會作動"
	else
		print_info "effectHint" "assignment effect 為 $assignment_effect"
	fi
fi

if [[ "$definition_found" != true || "$initiative_found" != true || "$reference_found" != true ]]; then
	echo "建議先修正 definition 或 initiative 部署狀態，再檢查 assignment。"
	exit 1
fi

exit 0