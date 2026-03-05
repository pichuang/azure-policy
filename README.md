# Azure Policy

## 需要手動加入

- Keys using elliptic curve cryptography should have the specified curve names
  - /providers/Microsoft.Authorization/policyDefinitions/ff25f3c8-b739-4538-9d07-3d6d25cfb255
- Keys using RSA cryptography should have a specified minimum key size
  - /providers/Microsoft.Authorization/policyDefinitions/82067dbb-e53b-4e06-b631-546d197452d9
- Keys should be backed by a hardware security module (HSM)
  - /providers/Microsoft.Authorization/policyDefinitions/587c79fe-dd04-4a5e-9d0b-f89598c7261b
- Not allowed resource types
  - /providers/Microsoft.Authorization/policyDefinitions/6c112d4e-5bc7-47ae-a041-ea2d9dccd749
- Add system-assigned managed identity to enable Guest Configuration assignments on virtual machines with no identities
- Deploy the Windows Guest Configuration extension to enable Guest Configuration assignments
- Deploy the Linux Guest Configuration extension to enable Guest Configuration assignments on Linux VMs
