# Contributing

Issues and pull requests are welcome.

## Workflow

1. Fork the repository and create a branch from `main`.
2. Follow `docs/ARCHITECTURE.md`: who owns what, and the three wrappers
   (`scripts/compose.sh`, `scripts/tf.sh`, `scripts/ansible.sh`).
3. Run the checks before you open a pull request: `make lint`,
   `make test-unit`, and on a running lab `make verify` and `make test-ui`.
4. Describe what changed and how you proved it.

## Rules

- Never commit a token, key, licence, password or private key. `.env`,
  `.secrets/` and `.build/` stay local; fixtures use synthetic values.
- No em dashes in docs, comments or UI text.
