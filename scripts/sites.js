#!/usr/bin/env node
// scripts/sites.js: the topology in config/sites.json, checked and printed.
//
//   node scripts/sites.js check       validate sites.json and the ports in defaults.conf (+ .env)
//   node scripts/sites.js sites       site ids, one per line
//   node scripts/sites.js nodes <id>  that site's Vault hostnames, one per line
//   node scripts/sites.js primary     the site that is primary at bootstrap
//
// Exits 1 with a plain message when the topology is wrong. Standard library only.
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROLES = ['primary', 'performance', 'dr'];

export function readConf(...files) {
  const conf = {};
  for (const f of files) {
    if (!existsSync(f)) continue;
    for (const line of readFileSync(f, 'utf8').split('\n')) {
      const m = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
      if (m) conf[m[1]] = m[2];
    }
  }
  return conf;
}

export const nodesOf = (site) => Array.from({ length: site.nodes }, (_, i) => `vault-${site.id}-${i + 1}`);

export function portName(host) {
  const seal = /^seal-([a-z]+)$/.exec(host);
  if (seal) return `VBAL_PORT_SEAL_${seal[1].toUpperCase()}`;
  const node = /^vault-([a-z]+)-(\d+)$/.exec(host);
  if (node) return `VBAL_PORT_VAULT_${node[1].toUpperCase()}_${node[2]}`;
  throw new Error(`unknown host ${host}`);
}

// Returns a list of problems; empty means the topology is valid.
export function check(topology, conf) {
  const errors = [];
  const sites = topology?.sites;
  if (!Array.isArray(sites) || sites.length === 0) return ['sites.json: "sites" must be a non-empty array'];
  const ids = new Set();
  for (const s of sites) {
    if (!/^[a-z]{3}$/.test(s.id ?? '')) errors.push(`site id "${s.id}" must be three lowercase letters`);
    if (ids.has(s.id)) errors.push(`site id "${s.id}" appears twice`);
    ids.add(s.id);
    if (!ROLES.includes(s.role)) errors.push(`site ${s.id}: role must be one of ${ROLES.join(', ')}`);
    if (!Number.isInteger(s.nodes) || s.nodes < 1 || s.nodes > 5) errors.push(`site ${s.id}: nodes must be 1 to 5`);
    if (!s.name) errors.push(`site ${s.id}: name is missing`);
  }
  const primaries = sites.filter((s) => s.role === 'primary').length;
  if (primaries !== 1) errors.push(`exactly one site must be primary (found ${primaries})`);
  if (errors.length) return errors;

  const seen = new Map();
  const want = (name) => {
    const v = conf[name];
    if (!/^\d+$/.test(v ?? '')) return errors.push(`${name} is not set to a port in config/defaults.conf or .env`);
    const p = Number(v);
    if (p < 1024 || p > 65535) errors.push(`${name}=${p} is outside 1024-65535`);
    if (seen.has(p)) errors.push(`${name}=${p} is also ${seen.get(p)}`);
    seen.set(p, name);
  };
  for (const s of sites) {
    want(portName(`seal-${s.id}`));
    nodesOf(s).forEach((n) => want(portName(n)));
  }
  ['VBAL_PORT_FRONTDOOR', 'VBAL_PORT_STATS', 'VBAL_PORT_WEB', 'VBAL_PORT_API'].forEach(want);
  return errors;
}

function main(argv) {
  const root = join(dirname(fileURLToPath(import.meta.url)), '..');
  const topology = JSON.parse(readFileSync(join(root, 'config/sites.json'), 'utf8'));
  const conf = readConf(join(root, 'config/defaults.conf'), join(root, '.env'));
  const [cmd, arg] = argv;
  const site = (id) => topology.sites.find((s) => s.id === id) ?? fail(`unknown site "${id}"`);
  switch (cmd) {
    case 'check': {
      const errors = check(topology, conf);
      if (errors.length) fail(errors.join('\n'));
      const summary = topology.sites.map((s) => `${s.id} (${s.role}, ${s.nodes} nodes)`).join(', ');
      console.log(`config/sites.json: ok: ${summary}`);
      break;
    }
    case 'sites':
      topology.sites.forEach((s) => console.log(s.id));
      break;
    case 'nodes':
      nodesOf(site(arg)).forEach((n) => console.log(n));
      break;
    case 'primary':
      console.log(topology.sites.find((s) => s.role === 'primary').id);
      break;
    default:
      fail('Usage: sites.js check | sites | nodes <site> | primary');
  }
}

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
