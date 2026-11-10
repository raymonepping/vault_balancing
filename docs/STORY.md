# When a Site Dies

> **Terraform builds the house. Ansible decorates it. Vault keeps the keys.
> Make is the front door.**

A region failover drill for Vault Enterprise 2.2, on one Mac. Three sites,
each a three-node Raft cluster with its own seal Vault. Amsterdam is the
primary. Frankfurt is a Performance Replication secondary that serves reads
near its users. Dublin is a DR Replication secondary that waits. A ticker
writes four times a second through an HAProxy front door until Amsterdam
dies.

## The acts

| Act | What happens | Vault feature | What the room sees |
| --- | --- | --- | --- |
| 0: A normal day | The ticker writes through the front door to Amsterdam; Frankfurt serves reads; Dublin streams | Performance and DR Replication, performance standbys | Three sites green, write latency, replication lag |
| I: Amsterdam goes dark | `make site-down SITE=ams` stops the whole site, seal Vault included | none (the outage itself) | Writes fail; Frankfurt still serves reads; the RTO clock starts |
| II: The decision | Promote Dublin with the DR operation token minted yesterday | `sys/replication/dr/secondary/promote` | Dublin answers 200, HAProxy routes to it on its own, the first write succeeds |
| III: Frankfurt follows | Point Frankfurt at the new primary | `update-primary` with an activation token from Dublin | Frankfurt's writes work again |
| IV: The ghost returns | Amsterdam comes back believing it is primary | a durable fence at the front door, `sys/replication/dr/primary/demote` | Fenced before it can take traffic, demoted, re-attached as Dublin's DR secondary |
| V: Back home | Planned failback to the original roles | demote, promote, update-primary in order | Zero acknowledged writes lost |
| Epilogue: The report | RTO, RPO, every step and Vault's answer | the drill journal, file audit devices | "Amsterdam died at 14:01:15. Clients wrote again at 14:01:27, 11.3 s later. We lost 0 s of writes (0 of 239). Nobody guessed." |

The last line is a real report (`make report`, 2026-11-10).

## What it proves

- A DR promotion needs only a pre-minted DR operation token: no recovery keys
  at 3 a.m.
- A performance secondary keeps serving reads while its primary is gone.
- The front door needs no manual repoint: each node's health code carries its
  role.
- An old primary can be fenced and demoted without split brain.
- RTO and RPO are measured, not estimated.

## What it only illustrates

One Mac is not three regions. Network latency, real data volumes and real
DNS are not modelled; the numbers describe this lab only.
