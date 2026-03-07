#!/bin/bash

set -euo pipefail

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
MANAGEMENT_GROUP_ID="${MANAGEMENT_GROUP_ID:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
TARGET_RESOURCE_ID="${TARGET_RESOURCE_ID:-}"
DEFINITION_REFERENCE_ID="${DEFINITION_REFERENCE_ID:-}"
RESOURCE_DISCOVERY_MODE="${RESOURCE_DISCOVERY_MODE:-ReEvaluateCompliance}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
POLL_TIMEOUT="${POLL_TIMEOUT:-1800}"
SHOW_RAW_JSON="${SHOW_RAW_JSON:-false}"

declare -a ASSIGNMENTS=()
declare -a LOCATION_FILTERS=()

usage() {
	cat <<'EOF'
用法：
  ./3-force-remediation.sh --assignment <assignment-name-or-id> [--assignment <assignment-name-or-id> ...] [options]

必要參數：
  --assignment                 指定要強制執行的 Azure Policy Assignment，可重複帶入多次。

可選參數：
  --definition-reference-id    Initiative 內單一 policy 的 policyDefinitionReferenceId。
  --management-group           Management Group 名稱。
  --resource-group             Resource Group 名稱。
  --resource                   Resource scope 的 resource ID。
  --subscription               Subscription ID 或名稱。
  --location-filter            僅修復指定 Azure 區域，可重複帶入多次。
  --resource-discovery-mode    ExistingNonCompliant 或 ReEvaluateCompliance，預設為 ReEvaluateCompliance。
  --poll-interval              輪詢秒數，預設 10。
  --poll-timeout               最長等待秒數，預設 1800。
  --show-raw-json              額外輸出 remediation 與 deployment 的原始 JSON。
  -h, --help                   顯示說明。

範例：
  ./3-force-remediation.sh \
    --subscription 00000000-0000-0000-0000-000000000000 \
    --assignment my-storage-assignment

  ./3-force-remediation.sh \
    --management-group contoso-platform \
    --assignment "/providers/Microsoft.Management/managementGroups/contoso-platform/providers/Microsoft.Authorization/policyAssignments/asg-storage" \
    --assignment "/providers/Microsoft.Management/managementGroups/contoso-platform/providers/Microsoft.Authorization/policyAssignments/asg-vm"

  ./3-force-remediation.sh \
    --assignment my-initiative-assignment \
    --definition-reference-id scarecrow-a1b2c3d4e5f6
EOF
}

require_command() {
	local cmd="$1"

	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "找不到必要指令：$cmd"
		exit 1
	fi
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

build_global_scope_args() {
	GLOBAL_SCOPE_ARGS=()

	if [[ -n "$SUBSCRIPTION_ID" ]]; then
		GLOBAL_SCOPE_ARGS+=(--subscription "$SUBSCRIPTION_ID")
	fi

	if [[ -n "$MANAGEMENT_GROUP_ID" ]]; then
		GLOBAL_SCOPE_ARGS+=(--management-group "$MANAGEMENT_GROUP_ID")
	elif [[ -n "$RESOURCE_GROUP" ]]; then
		GLOBAL_SCOPE_ARGS+=(--resource-group "$RESOURCE_GROUP")
	elif [[ -n "$TARGET_RESOURCE_ID" ]]; then
		GLOBAL_SCOPE_ARGS+=(--resource "$TARGET_RESOURCE_ID")
	fi
}

infer_scope_args_from_assignment_id() {
	local assignment_id="$1"
	local scope_base="${assignment_id%/providers/Microsoft.Authorization/policyAssignments/*}"
	local subscription_from_id=""

	INFERRED_SCOPE_ARGS=()

	if [[ "$scope_base" == /providers/Microsoft.Management/managementGroups/* ]]; then
		INFERRED_SCOPE_ARGS+=(--management-group "${scope_base##*/}")
		return 0
	fi

	if [[ "$scope_base" == /subscriptions/* ]]; then
		subscription_from_id="$(printf '%s\n' "$scope_base" | cut -d'/' -f3)"
		if [[ -n "$subscription_from_id" ]]; then
			INFERRED_SCOPE_ARGS+=(--subscription "$subscription_from_id")
		fi

		if [[ "$scope_base" == /subscriptions/*/resourceGroups/*/providers/* ]]; then
			INFERRED_SCOPE_ARGS+=(--resource "$scope_base")
		elif [[ "$scope_base" == /subscriptions/*/resourceGroups/* ]]; then
			INFERRED_SCOPE_ARGS+=(--resource-group "$(printf '%s\n' "$scope_base" | cut -d'/' -f5)")
		fi
	fi
}

extract_state_metric() {
	local json="$1"
	local key="$2"

	jq -r --arg key "$key" '
		(.value[0].results? // .results? // {})[$key] // "n/a"
	' <<<"$json"
}

print_policy_state_summary() {
	local label="$1"
	local json="$2"

	echo "$label"
	echo "  nonCompliantResources: $(extract_state_metric "$json" "nonCompliantResources")"
	echo "  nonCompliantPolicies: $(extract_state_metric "$json" "nonCompliantPolicies")"
	echo "  compliantResources: $(extract_state_metric "$json" "compliantResources")"
	echo "  compliantPolicies: $(extract_state_metric "$json" "compliantPolicies")"
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

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--assignment)
				ASSIGNMENTS+=("$2")
				shift 2
				;;
			--definition-reference-id)
				DEFINITION_REFERENCE_ID="$2"
				shift 2
				;;
			--management-group)
				MANAGEMENT_GROUP_ID="$2"
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
			--subscription)
				SUBSCRIPTION_ID="$2"
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
			--show-raw-json)
				SHOW_RAW_JSON=true
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

	if [[ ${#ASSIGNMENTS[@]} -eq 0 ]]; then
		echo "至少要指定一個 --assignment"
		usage
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
}

require_command az
require_command jq

parse_args "$@"
build_global_scope_args

if ! az account show >/dev/null 2>&1; then
	echo "尚未登入 Azure，請先執行：az login"
	exit 1
fi

overall_exit_code=0

for assignment in "${ASSIGNMENTS[@]}"; do
	assignment_name="$(extract_assignment_name "$assignment")"
	remediation_name="force-$(sanitize_name "$assignment_name")-$(date +%Y%m%d%H%M%S)"
	scope_source="使用命令列指定 scope"

	CURRENT_SCOPE_ARGS=("${GLOBAL_SCOPE_ARGS[@]}")

	if [[ ${#CURRENT_SCOPE_ARGS[@]} -eq 0 && $(is_assignment_id "$assignment"; echo $?) -eq 0 ]]; then
		infer_scope_args_from_assignment_id "$assignment"
		CURRENT_SCOPE_ARGS=("${INFERRED_SCOPE_ARGS[@]}")
		scope_source="從 assignment resource ID 推導 scope"
	fi

	echo
	echo "=== 開始處理 assignment: $assignment_name ==="
	echo "scope 來源: $scope_source"
	if [[ ${#CURRENT_SCOPE_ARGS[@]} -gt 0 ]]; then
		echo "scope 參數: ${CURRENT_SCOPE_ARGS[*]}"
	else
		echo "scope 參數: <subscription 預設 scope>"
	fi

	before_summary_json="$(az policy state summarize "${CURRENT_SCOPE_ARGS[@]}" -a "$assignment_name" -o json)"
	print_policy_state_summary "建立 remediation 前的合規摘要：" "$before_summary_json"

	create_args=(policy remediation create "${CURRENT_SCOPE_ARGS[@]}" --name "$remediation_name" --policy-assignment "$assignment" --resource-discovery-mode "$RESOURCE_DISCOVERY_MODE" -o json)

	if [[ -n "$DEFINITION_REFERENCE_ID" ]]; then
		create_args+=(--definition-reference-id "$DEFINITION_REFERENCE_ID")
	fi

	if [[ ${#LOCATION_FILTERS[@]} -gt 0 ]]; then
		create_args+=(--location-filters "${LOCATION_FILTERS[@]}")
	fi

	set +e
	create_output="$(az "${create_args[@]}" 2>&1)"
	create_status=$?
	set -e

	if [[ $create_status -ne 0 ]]; then
		echo "建立 remediation 失敗：$assignment_name"
		echo "$create_output"
		overall_exit_code=1
		continue
	fi

	remediation_json="$create_output"
	echo "已建立 remediation。"
	print_remediation_summary "$remediation_json"

	start_epoch="$(date +%s)"
	final_state=""

	while true; do
		remediation_json="$(az policy remediation show "${CURRENT_SCOPE_ARGS[@]}" --name "$remediation_name" -o json)"
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
			overall_exit_code=1
			break
		fi

		sleep "$POLL_INTERVAL"
		done

	echo "最終 remediation 狀態："
	print_remediation_summary "$remediation_json"

	deployments_json="$(az policy remediation deployment list "${CURRENT_SCOPE_ARGS[@]}" --name "$remediation_name" -o json)"
	echo "deployment 摘要："
	print_deployment_summary "$deployments_json"

	after_summary_json="$(az policy state summarize "${CURRENT_SCOPE_ARGS[@]}" -a "$assignment_name" -o json)"
	print_policy_state_summary "建立 remediation 後的合規摘要：" "$after_summary_json"

	if [[ "$SHOW_RAW_JSON" == true ]]; then
		echo "remediation JSON："
		echo "$remediation_json" | jq .
		echo "deployment JSON："
		echo "$deployments_json" | jq .
	fi

	if [[ "$final_state" != "Succeeded" ]]; then
		overall_exit_code=1
	fi
	done

exit "$overall_exit_code"
