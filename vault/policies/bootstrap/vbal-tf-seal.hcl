# vbal-tf-seal: Terraform root terraform/seal on each seal Vault (D7). Declared, plannable
# structure only: the Transit mount and key, the autounseal policy, the token
# role, the audit device. It may NOT mint a seal token from the role: issuing
# tokens is an act with a moment, and that is Ansible's job (seal-tokens).
# Written once by Ansible (seal-init) with the init root token; nothing can
# widen it afterwards except a user-run make root-regen CLUSTER=seal-<site>.

path "sys/mounts" { capabilities = ["read"] }
path "sys/mounts/transit" { capabilities = ["create", "read", "update", "delete"] }
path "sys/mounts/transit/tune" { capabilities = ["read", "update"] }

path "transit/keys/autounseal" { capabilities = ["create", "read", "update"] }
path "transit/keys/autounseal/config" { capabilities = ["update"] }

path "sys/policies/acl/autounseal" { capabilities = ["create", "read", "update", "delete"] }
path "sys/policy/autounseal" { capabilities = ["create", "read", "update", "delete"] }

path "auth/token/roles/autounseal" { capabilities = ["create", "read", "update", "delete"] }

# Audit devices need sudo (Vault requires it on sys/audit/*).
path "sys/audit" { capabilities = ["read", "sudo"] }
path "sys/audit/file" { capabilities = ["create", "read", "update", "delete", "sudo"] }

# The provider's short-lived child token (a subset of this policy).
path "auth/token/create" { capabilities = ["update"] }

# Never: mint a seal token, or rewrite a tool's own permissions.
path "auth/token/create/autounseal" { capabilities = ["deny"] }
path "sys/policies/acl/vbal-tf-*" { capabilities = ["deny"] }
path "sys/policies/acl/vbal-ansible-*" { capabilities = ["deny"] }
