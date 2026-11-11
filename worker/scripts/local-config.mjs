import fs from 'node:fs';
import path from 'node:path';

export function resolveLocalConfig(workerRoot, environment, args) {
  if (args.some(arg => arg === '--config' || arg.startsWith('--config=') || arg.startsWith('-c') || arg === '--cwd' || arg.startsWith('--cwd='))) {
    throw new Error('Use wrangler.local.json for local settings. Configuration and working-directory overrides are not accepted.');
  }
  const local = path.join(workerRoot, 'wrangler.local.json');
  const configPath = fs.existsSync(local) ? local : path.join(workerRoot, 'wrangler.jsonc');
  let config;
  try { config = JSON.parse(fs.readFileSync(configPath, 'utf8')); }
  catch { throw new Error('Cannot read the Worker configuration. Keep wrangler.local.json as valid JSON.'); }
  if (!config || typeof config !== 'object' || Array.isArray(config)) throw new Error('The Worker configuration must be a JSON object.');
  const account = config.account_id;
  if (typeof account !== 'string' || !/^[a-f0-9]{32}$/i.test(account)) {
    throw new Error('Copy wrangler.jsonc to wrangler.local.json and set your explicit 32-character Cloudflare account_id before running Wrangler.');
  }
  for (const name of ['CLOUDFLARE_ACCOUNT_ID', 'CF_ACCOUNT_ID']) {
    if (environment[name] && environment[name] !== account) {
      throw new Error(`${name} does not match the selected configuration. No Wrangler command was run.`);
    }
  }
  for (const value of Object.values(config.env ?? {})) {
    if (value.account_id !== undefined && value.account_id !== account) {
      throw new Error('An environment selects a different Cloudflare account. Use the same explicit account_id throughout the local configuration.');
    }
  }
  const env = { ...environment, CLOUDFLARE_ACCOUNT_ID: account };
  const localProfile = path.join(workerRoot, '.wrangler', 'personal-config');
  if (!env.XDG_CONFIG_HOME && fs.existsSync(path.join(localProfile, '.wrangler', 'config', 'default.toml'))) {
    env.XDG_CONFIG_HOME = localProfile;
  }
  return { configPath, env };
}
