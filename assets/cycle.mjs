#!/usr/bin/env node
// cycle.mjs — bookkeeping runner for cyclic-task loops (v1).
//
// Keeps the state header, design snapshots, the review ledger and the
// progress series of one loop so that the task texts never do arithmetic.
// Dependency-free; Node >= 20.
//
// Usage:
//   node cycle.mjs <doc-dir> state get <key>
//   node cycle.mjs <doc-dir> state set <key> <value...>
//   node cycle.mjs <doc-dir> state init <key=value>...
//   node cycle.mjs <doc-dir> snapshot <label>
//   node cycle.mjs <doc-dir> diff <labelA> [<labelB>]
//   node cycle.mjs <doc-dir> ledger add <id> <kind> <target> <text...>
//   node cycle.mjs <doc-dir> ledger set <id> <status> [note...]
//   node cycle.mjs <doc-dir> ledger list [status]
//   node cycle.mjs <doc-dir> progress append <value>      # progress only if the move is >= progress-step
//   node cycle.mjs <doc-dir> progress hold <value>        # value recorded, no-progress counter untouched (a defect card closed)
//   node cycle.mjs <doc-dir> progress rebaseline <value>  # contract-definition defect; refused on the 3rd within a milestone
//   node cycle.mjs <doc-dir> progress reset <value>       # milestone switch: starts a new segment ('||'), counter reset
//   node cycle.mjs <doc-dir> cycle advance
//
// <doc-dir> is docs/<slug>; the design doc is docs/<slug>/<slug>.md and the
// ledger is docs/<slug>/<slug>-review.md. All commands exit non-zero on a
// malformed header so that a caller notices instead of guessing.

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const HEADER_KEYS = [
  'status', 'design-round', 'cycle', 'current-milestone', 'milestones', 'risks',
  'progress', 'progress-step', 'no-progress-cycles', 'rebaselines', 'reentries', 'next-step',
];
const LEDGER_KINDS = ['blocking', 'note', 'out-of-scope'];
const LEDGER_STATUS = ['open', 'closed', 'rebutted', 'note'];

function fail(msg) {
  process.stderr.write(`[cycle] ${msg}\n`);
  process.exit(1);
}

function paths(docDir) {
  const dir = path.resolve(docDir);
  const slug = path.basename(dir);
  return {
    dir,
    slug,
    design: path.join(dir, `${slug}.md`),
    ledger: path.join(dir, `${slug}-review.md`),
    evidence: path.join(dir, 'evidence'),
    reference: path.join(dir, 'reference'),
  };
}

// ---------- state header ----------

function readHeader(designPath) {
  if (!fs.existsSync(designPath)) fail(`design doc not found: ${designPath}`);
  const text = fs.readFileSync(designPath, 'utf8');
  const m = text.match(/```text\n([\s\S]*?)\n```/);
  if (!m) fail('no ```text header block in design doc');
  const lines = m[1].split('\n');
  const fields = new Map();
  for (const line of lines) {
    const mm = line.match(/^([a-z-]+):\s?(.*)$/);
    if (mm) fields.set(mm[1], mm[2]);
  }
  return { text, block: m[0], fields, start: m.index, end: m.index + m[0].length };
}

function writeHeader(designPath, header) {
  const body = HEADER_KEYS
    .filter((k) => header.fields.has(k))
    .map((k) => `${k}: ${header.fields.get(k)}`);
  for (const [k, v] of header.fields) if (!HEADER_KEYS.includes(k)) body.push(`${k}: ${v}`);
  const block = '```text\n' + body.join('\n') + '\n```';
  const text = header.text.slice(0, header.start) + block + header.text.slice(header.end);
  fs.writeFileSync(designPath, text);
}

function stateCmd(p, args) {
  const [sub, key, ...rest] = args;
  if (sub === 'init') {
    if (!fs.existsSync(p.design)) fail(`design doc must exist before init: ${p.design}`);
    const text = fs.readFileSync(p.design, 'utf8');
    const fields = new Map();
    for (const k of HEADER_KEYS) fields.set(k, '');
    fields.set('status', '立项中');
    fields.set('design-round', '0/3');
    fields.set('cycle', '0/0');
    fields.set('progress-step', '1');
    fields.set('no-progress-cycles', '0');
    fields.set('rebaselines', '0');
    fields.set('reentries', '0');
    fields.set('next-step', '待评审');
    for (const kv of [key, ...rest].filter(Boolean)) {
      const i = kv.indexOf('=');
      if (i < 0) fail(`init expects key=value, got ${kv}`);
      fields.set(kv.slice(0, i), kv.slice(i + 1));
    }
    const block = '```text\n' + HEADER_KEYS.map((k) => `${k}: ${fields.get(k)}`).join('\n') + '\n```';
    const existing = text.match(/```text\n[\s\S]*?\n```/);
    const out = existing ? text.replace(existing[0], block) : block + '\n\n' + text;
    fs.writeFileSync(p.design, out);
    process.stdout.write(block + '\n');
    return;
  }
  const header = readHeader(p.design);
  if (sub === 'get') {
    if (!header.fields.has(key)) fail(`unknown key ${key}`);
    process.stdout.write(header.fields.get(key) + '\n');
    return;
  }
  if (sub === 'set') {
    if (!key) fail('state set needs a key');
    header.fields.set(key, rest.join(' '));
    writeHeader(p.design, header);
    process.stdout.write(`${key}: ${header.fields.get(key)}\n`);
    return;
  }
  fail(`unknown state subcommand ${sub}`);
}

// ---------- snapshots ----------

function copyDir(src, dst) {
  fs.mkdirSync(dst, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    const d = path.join(dst, entry.name);
    if (entry.isDirectory()) copyDir(s, d);
    else fs.copyFileSync(s, d);
  }
}

function snapshotCmd(p, args) {
  const [label] = args;
  if (!label) fail('snapshot needs a label, e.g. design-d1');
  const dst = path.join(p.evidence, label);
  if (fs.existsSync(dst)) fail(`snapshot ${label} already exists; labels are immutable`);
  fs.mkdirSync(dst, { recursive: true });
  fs.copyFileSync(p.design, path.join(dst, `${p.slug}.md`));
  if (fs.existsSync(p.ledger)) fs.copyFileSync(p.ledger, path.join(dst, `${p.slug}-review.md`));
  if (fs.existsSync(p.reference)) copyDir(p.reference, path.join(dst, 'reference'));
  process.stdout.write(`snapshot written: ${path.relative(process.cwd(), dst)}\n`);
}

function diffCmd(p, args) {
  const [a, b] = args;
  if (!a) fail('diff needs at least one snapshot label');
  const fileA = path.join(p.evidence, a, `${p.slug}.md`);
  const fileB = b ? path.join(p.evidence, b, `${p.slug}.md`) : p.design;
  for (const f of [fileA, fileB]) if (!fs.existsSync(f)) fail(`missing: ${f}`);
  const r = spawnSync('diff', ['-u', fileA, fileB], { encoding: 'utf8' });
  if (r.error) fail(`diff unavailable: ${r.error.message}`);
  process.stdout.write(r.stdout || '(no differences)\n');
}

// ---------- review ledger ----------

const LEDGER_HEADER = [
  '# 设计评审账本',
  '',
  '跨轮追加，不覆盖。类别：blocking（阻塞）、note（注意事项）、out-of-scope（范围外）。状态：open、closed、rebutted、note。',
  '',
  '| id | 轮次 | 类别 | 攻击对象 | 后果或内容 | 状态 | 处置说明 |',
  '|---|---|---|---|---|---|---|',
].join('\n');

function readLedger(p) {
  if (!fs.existsSync(p.ledger)) return { text: LEDGER_HEADER + '\n', rows: [] };
  const text = fs.readFileSync(p.ledger, 'utf8');
  const rows = [];
  for (const line of text.split('\n')) {
    const m = line.match(/^\|\s*([A-Za-z]+-\d+)\s*\|/);
    if (m) rows.push({ id: m[1], line });
  }
  return { text, rows };
}

function currentRound(p) {
  if (!fs.existsSync(p.design)) return 'd?';
  const h = readHeader(p.design);
  const d = (h.fields.get('design-round') || '0').split('/')[0];
  const c = (h.fields.get('cycle') || '0').split('/')[0];
  return h.fields.get('status') === '实现中' ? `c${c}` : `d${d}`;
}

function esc(s) {
  return String(s).replace(/\|/g, '\\|').replace(/\n/g, ' ');
}

function ledgerCmd(p, args) {
  const [sub, ...rest] = args;
  const ledger = readLedger(p);
  if (sub === 'add') {
    const [id, kind, target, ...textParts] = rest;
    if (!id || !kind || !target || textParts.length === 0) fail('ledger add <id> <kind> <target> <text...>');
    if (!LEDGER_KINDS.includes(kind)) fail(`kind must be one of ${LEDGER_KINDS.join(', ')}`);
    if (ledger.rows.some((r) => r.id === id)) fail(`ledger id ${id} already exists`);
    if (kind === 'blocking' && !/^(D-\d+|R-\d+|M-\d+|契约[:：].+|C-\d+)/.test(target)) fail(`blocking items must attack a D-n, R-n, M-n or 契约:<name>; got "${target}"`);
    const status = kind === 'blocking' ? 'open' : 'note';
    const row = `| ${id} | ${currentRound(p)} | ${kind} | ${esc(target)} | ${esc(textParts.join(' '))} | ${status} | |`;
    let text = ledger.text;
    // insert after the last table row so later prose sections stay below the table
    const lines = text.split('\n');
    let lastRow = -1;
    for (let i = 0; i < lines.length; i++) if (/^\|/.test(lines[i])) lastRow = i;
    if (lastRow < 0) fail('ledger has no table');
    lines.splice(lastRow + 1, 0, row);
    text = lines.join('\n');
    fs.writeFileSync(p.ledger, text);
    process.stdout.write(row + '\n');
    return;
  }
  if (sub === 'set') {
    const [id, status, ...noteParts] = rest;
    if (!id || !status) fail('ledger set <id> <status> [note...]');
    if (!LEDGER_STATUS.includes(status)) fail(`status must be one of ${LEDGER_STATUS.join(', ')}`);
    const row = ledger.rows.find((r) => r.id === id);
    if (!row) fail(`ledger id ${id} not found`);
    const cells = row.line.split('|');
    // cells: ['', id, round, kind, target, text, status, note, '']
    if (cells.length < 9) fail(`malformed ledger row for ${id}`);
    cells[6] = ` ${status} `;
    const prev = cells[7].trim();
    const note = noteParts.length ? `${currentRound(p)}: ${esc(noteParts.join(' '))}` : '';
    cells[7] = ` ${[prev, note].filter(Boolean).join('；')} `;
    const newLine = cells.join('|');
    fs.writeFileSync(p.ledger, ledger.text.replace(row.line, newLine));
    process.stdout.write(newLine + '\n');
    return;
  }
  if (sub === 'list') {
    const [status] = rest;
    for (const r of ledger.rows) {
      const cells = r.line.split('|').map((c) => c.trim());
      if (!status || cells[6] === status) process.stdout.write(r.line + '\n');
    }
    return;
  }
  fail(`unknown ledger subcommand ${sub}`);
}

// ---------- progress and cycles ----------

function parseProgress(value) {
  // "<name>(<down|up>): v0, v1 | v2, v3"   '|' marks a re-baseline boundary
  const m = value.match(/^(.+?)\((down|up)\):\s*(.*)$/);
  if (!m) fail(`progress field must look like "<name>(down|up): v0, v1", got "${value}"`);
  return { name: m[1].trim(), direction: m[2], series: m[3].trim() };
}

function lastValue(series) {
  const segs = series.split('|').filter((seg) => seg.trim() !== '');
  const last = (segs[segs.length - 1] || '').split(',').map((s) => s.trim()).filter(Boolean);
  return last.length ? Number(last[last.length - 1]) : null;
}

function progressCmd(p, args) {
  const [sub, raw] = args;
  if (!['append', 'hold', 'rebaseline', 'reset'].includes(sub)) fail('progress append|hold|rebaseline|reset <value>');
  const value = Number(raw);
  if (!Number.isFinite(value)) fail(`progress value must be a number, got ${raw}`);
  const header = readHeader(p.design);
  const prog = parseProgress(header.fields.get('progress') || '');
  const prev = lastValue(prog.series);
  let series = prog.series;
  let noProgress = Number(header.fields.get('no-progress-cycles') || 0);
  let verdict;
  if (sub === 'rebaseline') {
    const currentMilestone = series.split('||').pop();
    const inMilestone = (currentMilestone.match(/\|/g) || []).length;
    if (inMilestone >= 2) fail('third rebaseline in this milestone refused: record the value with `progress append` (counts as no progress) and make the structural change a completion condition');
    series = series ? `${series} | ${value}` : `${value}`;
    header.fields.set('rebaselines', String(Number(header.fields.get('rebaselines') || 0) + 1));
    noProgress = 0;
    header.fields.set('no-progress-cycles', '0');
    verdict = `REBASELINE #${inMilestone + 1} in this milestone`;
  } else if (sub === 'reset') {
    series = series ? `${series} || ${value}` : `${value}`;
    noProgress = 0;
    header.fields.set('no-progress-cycles', '0');
    verdict = 'RESET (new milestone segment)';
  } else if (sub === 'hold') {
    series = series ? `${series}, ${value}` : `${value}`;
    noProgress = 0;
    header.fields.set('no-progress-cycles', '0');
    verdict = 'HOLD';
  } else {
    series = series ? `${series}, ${value}` : `${value}`;
    if (prev === null) verdict = 'FIRST';
    else {
      const step = Number(header.fields.get('progress-step') || 1);
      if (!Number.isFinite(step) || step <= 0) fail(`progress-step must be a positive number, got ${header.fields.get('progress-step')}`);
      const move = prog.direction === 'down' ? prev - value : value - prev;
      if (move >= step) { noProgress = 0; verdict = 'PROGRESS'; }
      else { noProgress += 1; verdict = move > 0 ? `NO-PROGRESS (moved ${move} < step ${step})` : 'NO-PROGRESS'; }
    }
    header.fields.set('no-progress-cycles', String(noProgress));
  }
  header.fields.set('progress', `${prog.name}(${prog.direction}): ${series}`);
  writeHeader(p.design, header);
  process.stdout.write(`${verdict} ${prog.name}: ${prev === null ? '-' : prev} -> ${value}; no-progress-cycles=${noProgress}\n`);
}

function cycleCmd(p, args) {
  const [sub] = args;
  if (sub !== 'advance') fail('cycle advance');
  const header = readHeader(p.design);
  const m = (header.fields.get('cycle') || '').match(/^(\d+)\/(\d+)$/);
  if (!m) fail('cycle field must look like c/C');
  const c = Number(m[1]) + 1;
  const C = Number(m[2]);
  header.fields.set('cycle', `${c}/${C}`);
  writeHeader(p.design, header);
  process.stdout.write(`cycle ${c}/${C}${C > 0 && c >= C ? ' CEILING' : ''}\n`);
}

// ---------- main ----------

const [docDir, cmd, ...args] = process.argv.slice(2);
if (!docDir || !cmd) {
  process.stderr.write(fs.readFileSync(new URL(import.meta.url)).toString().split('\n').slice(1, 22).map((l) => l.replace(/^\/\/ ?/, '')).join('\n') + '\n');
  process.exit(2);
}
const p = paths(docDir);
switch (cmd) {
  case 'state': stateCmd(p, args); break;
  case 'snapshot': snapshotCmd(p, args); break;
  case 'diff': diffCmd(p, args); break;
  case 'ledger': ledgerCmd(p, args); break;
  case 'progress': progressCmd(p, args); break;
  case 'cycle': cycleCmd(p, args); break;
  default: fail(`unknown command ${cmd}`);
}
