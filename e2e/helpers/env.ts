// helpers/env.ts: where things are. Ports come from the same two files the
// stack reads (config/defaults.conf, overridden by .env).
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

export const ROOT = path.resolve(__dirname, '../..');

function readEnvFile(file: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (!fs.existsSync(file)) return out;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(line);
    if (m && m[1] !== 'VAULT_LICENSE') out[m[1]] = m[2];
  }
  return out;
}
const merged = { ...readEnvFile(path.join(ROOT, 'config/defaults.conf')), ...readEnvFile(path.join(ROOT, '.env')) };
export const conf = (name: string): string => {
  const v = merged[name];
  if (v === undefined) throw new Error(`configuration value ${name} is not set`);
  return v;
};
export const urls = { web: `https://localhost:${conf('VBAL_PORT_WEB')}` };

const spki = (pem: string) => crypto.createHash('sha256').update(crypto.createPublicKey(pem).export({ type: 'spki', format: 'der' })).digest('base64');
/** Chromium trusts exactly the lab leaf's and the lab CA's keys, never ignoreHTTPSErrors. */
export const labCaSpkiArg = (): string =>
  `--ignore-certificate-errors-spki-list=${spki(fs.readFileSync(path.join(ROOT, 'vault-tls/vault.crt'), 'utf8'))},${spki(fs.readFileSync(path.join(ROOT, 'vault-tls/ca-chain.pem'), 'utf8'))}`;
