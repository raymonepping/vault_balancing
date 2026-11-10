# vbal-dr-operations: the DR operations batch token (D9). Exactly what the
# operator needs on a DR secondary when the primary is gone: promote it, or
# point it at a new primary. Integrated storage also reads autopilot state.
# Terraform writes it (prompt 04); Ansible mints the token from the token role
# vbal-dr-operations, before it is needed. Prompt 03 proves the list.
path "sys/replication/dr/secondary/promote" { capabilities = ["update"] }
path "sys/replication/dr/secondary/update-primary" { capabilities = ["update"] }
path "sys/storage/raft/autopilot/state" { capabilities = ["update", "read"] }
