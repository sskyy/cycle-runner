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
  function exec(...args) {
    return spawnSync(process.execPath, [runner, dir, ...args], { encoding: 'utf8' });
  }
  function run(...args) {
    const result = exec(...args);
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  }
  run('state', 'init', ...Object.entries({
    status: '实现中', cycle: '0/9', 'current-milestone': 'M-01',
    milestones: '0/2', risks: '0/1', progress: 'remaining(down): 7', ...fields,
  }).map(([key, value]) => `${key}=${value}`));
  return { dir, design, run, exec, get: key => run('state', 'get', key) };
}

test('the header carries facts only: no stagnation counter, step or rebaseline count', t => {
  const { design } = fixture(t);
  const header = fs.readFileSync(design, 'utf8');
  for (const key of ['progress-step', 'no-progress-cycles', 'rebaselines']) assert.doesNotMatch(header, new RegExp(`^${key}:`, 'm'));
  assert.match(header, /^reentries: 0$/m);
});

test('a flat or falling series is recorded without any verdict', t => {
  const { run, get } = fixture(t, { progress: 'slice(down): 0' });
  for (const value of ['0', '0', '3']) {
    const out = run('progress', 'append', value);
    assert.doesNotMatch(out, /PROGRESS|NO-PROGRESS|REVIEW/);
  }
  assert.equal(get('progress'), 'slice(down): 0, 0, 0, 3');
  assert.equal(get('status'), '实现中');
});

test('redefining the measure keeps the earlier series and starts from the measured value', t => {
  const { run, get } = fixture(t, { progress: 'adjudicated(up): 95, 92, 77' });
  run('progress', 'redefine', 'fail+unknown(down)', '105');
  assert.equal(get('progress'), 'fail+unknown(down): 95, 92, 77 || 105');
  run('progress', 'append', '87');
  assert.equal(get('progress'), 'fail+unknown(down): 95, 92, 77 || 105, 87');
});

test('reaching the estimate is reported as a plain count, never as a trigger or a status', t => {
  const { run, get } = fixture(t, { cycle: '8/9' });
  assert.equal(run('cycle', 'advance'), 'cycle 9/9');
  assert.equal(run('cycle', 'advance'), 'cycle 10/9');
  assert.equal(get('status'), '实现中');
});

test('malformed progress commands fail instead of guessing', t => {
  const { exec } = fixture(t);
  assert.notEqual(exec('progress', 'hold', '3').status, 0);
  assert.notEqual(exec('progress', 'redefine', 'no-direction', '3').status, 0);
  assert.notEqual(exec('progress', 'append', 'many').status, 0);
});

test('a measurement change preserves the previous design in an immutable snapshot', t => {
  const { dir, design, run, get } = fixture(t, { progress: 'slice(down): 7, 0, 0', cycle: '9/49' });
  const before = fs.readFileSync(design, 'utf8');
  run('snapshot', 'review-c9');
  run('progress', 'redefine', 'open-obligations(down)', '3');
  assert.equal(get('progress'), 'open-obligations(down): 7, 0, 0 || 3');
  assert.equal(fs.readFileSync(path.join(dir, 'evidence/snapshots/review-c9/task.md'), 'utf8'), before);
  assert.notEqual(spawnSync(process.execPath, [runner, dir, 'snapshot', 'review-c9']).status, 0);
});

test('resuming a stopped task keeps its cycle and reentry history', t => {
  const { run, get } = fixture(t, { status: '停止尝试', cycle: '13/33', reentries: '1' });
  run('state', 'set', 'status', '实现中');
  run('state', 'set', 'next-step', '复评：保留证据，判断下一步');
  assert.equal(get('cycle'), '13/33');
  assert.equal(get('reentries'), '1');
});
