// Optional test using the same TypeScript loader installed alongside Pi 1.4.0.
// Usage: node scripts/check-pi-guard.mjs /path/to/pi-install/node_modules/jiti/lib/jiti.mjs
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
if (!process.argv[2]) throw new Error('Pass the jiti loader path from an isolated Pi 1.4.0 installation.');
const { createJiti } = await import(pathToFileURL(process.argv[2]).href);
const load = createJiti(import.meta.url);
const { default: extension } = await load.import('../Packages/SlimeCore/Sources/SlimeCore/Resources/mochlet-pi-guard.ts');
let checks = 0;
for (const readOnly of [false, true]) {
  process.env.MOCHLET_PI_READ_ONLY = readOnly ? '1' : '0';
  process.env.MOCHLET_PI_NONCE = 'test-nonce';
  let command, hook, notice, decision = false;
  let requested;
  extension({ registerCommand: (_, value) => { command = value.handler; },
    on: (_, value) => { hook = value; }, getActiveTools: () => ['read', 'bash'] });
  const ctx = { mode: 'rpc', cwd: '/fixture', signal: new AbortController().signal,
    sessionManager: { getSessionId: () => 'fixture', getSessionFile: () => '/fixture.jsonl' },
    ui: { notify: value => { notice = JSON.parse(value); }, confirm: async (...args) => {
      requested = args;
      if (decision === 'error') throw new Error('transport failed');
      return decision;
    } } };
  const write = { toolName: 'write', input: { path: 'fixture.txt', content: 'fixture' } };
  assert.equal((await hook(write, ctx)).block, true); checks++;
  await command('wrong-nonce', ctx);
  assert.equal((await hook(write, ctx)).block, true); checks++;
  await command('test-nonce', ctx);
  assert.equal(notice.nonce, 'test-nonce'); checks++;
  assert.equal(await hook({ toolName: 'read', input: {} }, ctx), undefined); checks++;
  assert.equal((await hook(write, ctx)).block, true); checks++;
  decision = true;
  if (readOnly) { assert.equal((await hook(write, ctx)).block, true); checks++; }
  else {
    assert.equal(await hook(write, ctx), undefined); checks++;
    assert.deepEqual(JSON.parse(requested[1]), { tool: 'write', input: write.input }); checks++;
    assert.equal(requested[2].signal, ctx.signal); checks++;
    decision = 'error'; assert.equal((await hook(write, ctx)).block, true); checks++;
  }
}
console.log(`Pi approval extension: ${checks} checks passed; no model or tool execution.`);
