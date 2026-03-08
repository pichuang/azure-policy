#!/bin/bash

set -euo pipefail

require_command() {
	local cmd="$1"

	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "找不到必要指令：$cmd"
		exit 1
	fi
}

ensure_azure_login() {
	if ! az account show >/dev/null 2>&1; then
		echo "尚未登入 Azure，請先執行：az login"
		exit 1
	fi
}

resolve_management_group_id() {
	local current_value="$1"

	if [[ -n "$current_value" ]]; then
		printf '%s\n' "$current_value"
		return 0
	fi

	az account show --query tenantId -o tsv
}

compute_stable_key() {
	local input="$1"

	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum | awk '{print $1}' | cut -c1-12
	elif command -v openssl >/dev/null 2>&1; then
		printf '%s' "$input" | openssl dgst -sha256 | awk '{print $NF}' | cut -c1-12
	elif command -v cksum >/dev/null 2>&1; then
		printf '%s' "$input" | cksum | awk '{print $1}'
	else
		echo "無法產生穩定雜湊，請安裝 sha256sum 或 openssl。"
		exit 1
	fi
}

build_management_group_scope_args() {
	local management_group_id="$1"

	MANAGEMENT_GROUP_SCOPE_ARGS=(--management-group "$management_group_id")
}