# Changelog

All notable changes to this project are documented in this file. The format
is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Three sites (Amsterdam primary, Frankfurt performance secondary, Dublin DR
  secondary), each a three-node Raft cluster with its own seal Vault, built
  by `make lab` from empty volumes with scoped tokens only.
- The HAProxy front door that follows each node's health code, with a durable
  fence.
- The ticker, the drill (`make drill`, one make target per act), the drill
  journal and the report (RTO as clients saw it, RPO, the planned failback).
- `make probe`: every replication move proven on scratch clusters
  (`docs/capabilities.md`).
- The read-only situation room API and console, Playwright with axe.
- Rehearsal, doctor, show-ready, backup, clean-slate.
