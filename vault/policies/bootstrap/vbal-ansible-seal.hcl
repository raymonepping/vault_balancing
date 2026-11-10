# vbal-ansible-seal: Ansible on each seal Vault (D7). The moment, not the structure:
# one seal token per node from the token role Terraform declared, lookup and
# revoke by accessor (make seal-token-rotate), Raft snapshots (make backup)
# and status reads. It may NOT change the role, the policy or the mount.
# Written once by Ansible (seal-init) with the init root token.

path "auth/token/create/autounseal" { capabilities = ["update"] }
path "auth/token/lookup" { capabilities = ["update"] }
path "auth/token/lookup-accessor" { capabilities = ["update"] }
path "auth/token/revoke-accessor" { capabilities = ["update"] }

path "sys/storage/raft/snapshot" { capabilities = ["read"] }
path "sys/storage/raft/configuration" { capabilities = ["read"] }
path "sys/license/status" { capabilities = ["read"] }
path "sys/health" { capabilities = ["read"] }
path "transit/keys/autounseal" { capabilities = ["read"] }

# Break glass (make root-regen): Vault 2.0 requires a token as well as the
# key share for sys/generate-root (HCSEC-2026-08). root-regen.sh sends this
# token.
path "sys/generate-root/*" { capabilities = ["create", "read", "update", "delete", "sudo"] }

# Never: Terraform's structure, or a tool's own permissions.
path "auth/token/roles/autounseal" { capabilities = ["deny"] }
path "sys/policies/acl/autounseal" { capabilities = ["deny"] }
path "sys/mounts/transit" { capabilities = ["deny"] }
path "sys/policies/acl/vbal-tf-*" { capabilities = ["deny"] }
path "sys/policies/acl/vbal-ansible-*" { capabilities = ["deny"] }
