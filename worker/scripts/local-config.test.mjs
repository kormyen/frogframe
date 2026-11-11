import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { resolveLocalConfig } from './local-config.mjs';

const account = '11111111111111111111111111111111';
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'phototab-config-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.writeFileSync(path.join(root, 'wrangler.jsonc'), JSON.stringify({ account_id: 'YOUR_CLOUDFLARE_ACCOUNT_ID' }));
  return root;
}

test('an unconfigured public checkout cannot run Wrangler', t => {
  const root = fixture(t);
  assert.throws(() => resolveLocalConfig(root, {}, ['deploy']), /explicit 32-character/);
});
test('local configuration and local authentication are selected without changing credentials', t => {
  const root = fixture(t);
  fs.writeFileSync(path.join(root, 'wrangler.local.json'), JSON.stringify({ account_id: account }));
  const profile = path.join(root, '.wrangler', 'personal-config');
  fs.mkdirSync(path.join(profile, '.wrangler', 'config'), { recursive: true });
  fs.writeFileSync(path.join(profile, '.wrangler', 'config', 'default.toml'), 'fixture');
  const result = resolveLocalConfig(root, { TEST_VALUE: 'preserved' }, ['deploy', '--dry-run']);
  assert.equal(result.configPath, path.join(root, 'wrangler.local.json'));
  assert.equal(result.env.XDG_CONFIG_HOME, profile);
  assert.equal(result.env.CLOUDFLARE_ACCOUNT_ID, account);
  assert.equal(result.env.CF_ACCOUNT_ID, undefined);
  assert.equal(result.env.TEST_VALUE, 'preserved');
});
test('a different environment account or config override is rejected', t => {
  const root = fixture(t);
  fs.writeFileSync(path.join(root, 'wrangler.local.json'), JSON.stringify({ account_id: account }));
  assert.throws(() => resolveLocalConfig(root, { CLOUDFLARE_ACCOUNT_ID: '22222222222222222222222222222222' }, ['deploy']), /does not match/);
  for (const args of [['deploy', '-c', 'other.json'], ['deploy', '--config=other.json'], ['deploy', '--cwd=elsewhere']]) {
    assert.throws(() => resolveLocalConfig(root, {}, args), /overrides are not accepted/);
  }
  fs.writeFileSync(path.join(root, 'wrangler.local.json'), JSON.stringify({ account_id: account, env: { production: { account_id: '22222222222222222222222222222222' } } }));
  assert.throws(() => resolveLocalConfig(root, {}, ['deploy', '--env', 'production']), /different Cloudflare account/);
});
test('an explicitly selected sign-in profile is preserved', t => {
  const root = fixture(t);
  fs.writeFileSync(path.join(root, 'wrangler.local.json'), JSON.stringify({ account_id: account }));
  const result = resolveLocalConfig(root, { XDG_CONFIG_HOME: '/chosen-profile' }, ['whoami']);
  assert.equal(result.env.XDG_CONFIG_HOME, '/chosen-profile');
});
