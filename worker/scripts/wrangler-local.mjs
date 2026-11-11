import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { resolveLocalConfig } from './local-config.mjs';

const workerRoot = fileURLToPath(new URL('../', import.meta.url));
const args = process.argv.slice(2);
try {
  const { configPath, env } = resolveLocalConfig(workerRoot, process.env, args);
  if (args.includes('--check-config')) {
    console.log(`Worker configuration: ${path.basename(configPath)}`);
    console.log('Explicit Cloudflare account: set');
    console.log(`Sign-in settings: ${env.XDG_CONFIG_HOME === path.join(workerRoot, '.wrangler', 'personal-config') ? 'local project profile' : 'current environment'}`);
  } else {
    const cli = path.join(workerRoot, 'node_modules', 'wrangler', 'bin', 'wrangler.js');
    if (!fs.existsSync(cli)) throw new Error('Install the Worker dependencies with npm ci first.');
    const result = spawnSync(process.execPath, [cli, ...args, '--config', configPath], {
      cwd: workerRoot, env, stdio: 'inherit'
    });
    if (result.error) throw new Error('Cannot start Wrangler.');
    process.exitCode = result.status ?? 1;
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
