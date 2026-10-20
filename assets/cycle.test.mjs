import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const runner = fileURLToPath(new URL('./cycle.mjs', import.meta.url));

function fixture(t, fields = {}) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'cycle-review-'));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const dir = path.join(temp, 'task');
  fs.mkdirSync(dir);
  const design = path.join(dir, 'task.md');
  fs.writeFileSync(design, '# Test task\n');
  function run(...args) {
    const result = spawnSync(process.execPath, [runner, dir, ...args], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  }
  run('state', 'init', ...Object.entries({
    status: '实现中', cycle: '0/9', 'current-milestone': 'M-01',
    milestones: '0/2', risks: '0/1', progress: 'remaining(down): 7',
    'progress-step': '1', ...fields,
  }).map(([key, value]) => `${key}=${value}`));
  return { dir, design, run, get: key => run('state', 'get', key) };
}

test('1670: a saturated measure records stagnation without deciding feasibility', t => {
  const { run, get } = fixture(t, { progress: 'slice(down): 0', 'progress-step': '5', reentries: '1' });
  for (let n = 1; n <= 3; n++) {
    run('progress', 'append', '0');
    assert.equal(get('no-progress-cycles'), String(n));
  }
  assert.equal(get('status'), '实现中');
  assert.equal(get('reentries'), '1');
  assert.equal(get('progress'), 'slice(down): 0, 0, 0, 0');
});

test('1542: withdrawing unsound judgments preserves the actual declining series', t => {
  const { run, get } = fixture(t, { progress: 'adjudicated(up): 95', 'progress-step': '89', cycle: '10/33' });
  for (const value of ['92', '77', '46']) run('progress', 'append', value);
  assert.equal(get('progress'), 'adjudicated(up): 95, 92, 77, 46');
  assert.equal(get('no-progress-cycles'), '3');
  assert.equal(get('status'), '实现中');
});

test('small genuine improvement remains visible even when below the review threshold', t => {
  const { run, get } = fixture(t, { progress: 'adjudicated(up): 252', 'progress-step': '31' });
  assert.match(run('progress', 'append', '281'), /moved 29 < step 31/);
  assert.equal(get('progress'), 'adjudicated(up): 252, 281');
  assert.equal(get('no-progress-cycles'), '1');
});

test('reaching an estimate signals review and never writes a terminal status', t => {
  const { run, get } = fixture(t, { cycle: '8/9' });
  assert.match(run('cycle', 'advance'), /9\/9 CEILING/);
  assert.equal(get('status'), '实现中');
  run('state', 'set', 'cycle', '9/14');
  assert.doesNotMatch(run('cycle', 'advance'), /CEILING/);
  assert.equal(get('cycle'), '10/14');
});

test('reviewed rebasing retains all history without refusing a third correction', t => {
  const { run, get } = fixture(t);
  for (const value of ['9', '12', '15']) {
    run('progress', 'append', value);
    run('progress', 'rebaseline', value);
  }
  assert.equal(get('progress'), 'remaining(down): 7, 9 | 9, 12 | 12, 15 | 15');
  assert.equal(get('rebaselines'), '3');
  assert.equal(get('no-progress-cycles'), '0');
  run('progress', 'append', '14');
  assert.equal(get('no-progress-cycles'), '0');
});

test('a measurement change preserves the previous definition in an immutable snapshot', t => {
  const { dir, design, run, get } = fixture(t, { progress: 'slice(down): 7, 0, 0', cycle: '9/49' });
  const before = fs.readFileSync(design, 'utf8');
  run('snapshot', 'review-c9');
  run('state', 'set', 'progress', 'open-obligations(down): 3');
  run('state', 'set', 'progress-step', '1');
  run('state', 'set', 'no-progress-cycles', '0');
  run('progress', 'append', '2');
  assert.equal(get('progress'), 'open-obligations(down): 3, 2');
  assert.equal(fs.readFileSync(path.join(dir, 'evidence/snapshots/review-c9/task.md'), 'utf8'), before);
  assert.equal(get('cycle'), '9/49');
});

test('resuming a stopped task does not erase its cycle, stagnation or reentry history', t => {
  const { run, get } = fixture(t, {
    status: '不可实现', cycle: '13/33', 'no-progress-cycles': '3', reentries: '1',
  });
  run('state', 'set', 'status', '实现中');
  run('state', 'set', 'next-step', '复评：保留证据，判断下一步');
  assert.equal(get('cycle'), '13/33');
  assert.equal(get('no-progress-cycles'), '3');
  assert.equal(get('reentries'), '1');
  run('state', 'set', 'status', '停止尝试');
  assert.equal(get('status'), '停止尝试');
});
