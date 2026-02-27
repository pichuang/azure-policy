#!/bin/bash

# 特定的 Subscription
SUBSCRIPTION_ID_LIST=(
  "a18feea9-5e4a-4a6a-b749-c15a28dbe757"
  "bd9804b4-cbe6-4eed-8a43-b3259d7e8ff5"
)

# 包含註解, name, namespace
FEATURE_REGISTER_MAPPING=(
    "啟用主機端加密功能:EncryptionAtHost:Microsoft.Compute"
)

for SUBSCRIPTION_ID in "${SUBSCRIPTION_ID_LIST[@]}"; do
  # 從 FEATURE_REGISTER_MAPPING 解析出註解, feature name 和 namespace
  IFS=':' read -r COMMENT FEATURE_NAME NAMESPACE <<< "${FEATURE_REGISTER_MAPPING[0]}"
  echo "正在訂閱 $SUBSCRIPTION_ID 啟用 $COMMENT..."
  az account set --subscription "$SUBSCRIPTION_ID"
  az feature register --name "$FEATURE_NAME" --namespace "$NAMESPACE"
done
