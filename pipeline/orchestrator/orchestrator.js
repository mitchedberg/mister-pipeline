#!/usr/bin/env node
/**
 * MiSTer Pipeline Orchestrator
 *
 * Reads targets.json, checks real filesystem state per target, and dispatches
 * Claude API agents to advance each target through the pipeline.
 *
 * Usage:
 *   node orchestrator.js [--target <id>] [--dry-run] [--all] [--publish <id>]
 *   node orchestrator.js --status
 */

'use strict';

const fs   = require('fs');
const path = require('path');
const { execSync, spawnSync } = require('child_process');
const Anthropic = require('@anthropic-ai/sdk');

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------
const REPO_ROOT    = path.resolve(__dirname, '../..');
const TARGETS_FILE = path.join(__dirname, 'targets.json');
const PROMPTS_DIR  = path.join(__dirname, 'prompts');
const LOG_FILE     = path.join(__dirname, 'orchestrator.log');

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------
const STATES = [
  'unresearched',
  'researched',
  'rtl_started',
  'tests_passing',
  'integrated',
  'synthesized',
  'validated',
  'published',
];

// For each state, define what agent handles the transition OUT of it.
// agent: 'haiku' | 'sonnet' | 'human' | 'none'
// task:  name of prompt template file (without .md)
const TRANSITIONS = {
  unresearched:  { agent: 'haiku',  task: 'research',         nextState: 'researched'    },
  researched:    { agent: 'sonnet', task: 'write_rtl',        nextState: 'rtl_started'   },
  rtl_started:   { agent: 'sonnet', task: 'fix_tests',        nextState: 'tests_passing' },
  tests_passing: { agent: 'haiku',  task: 'integrate',        nextState: 'integrated'    },
  integrated:    { agent: 'haiku',  task: 'synthesis_infra',  nextState: 'synthesized'   },
  synthesized:   { agent: 'human',  task: 'validate_hardware',nextState: 'validated'     },
  validated:     { agent: 'haiku',  task: 'prepare_release',  nextState: 'published'     },
  published:     { agent: 'none',   task: null,               nextState: null            },
};

// Approximate token costs per task (input + output combined, USD)
const COST_ESTIMATES = {
  research:         { model: 'haiku',  inputK: 80,  outputK: 8,  est: '$0.04' },
  write_rtl:        { model: 'sonnet', inputK: 60,  outputK: 40, est: '$0.90' },
  fix_tests:        { model: 'sonnet', inputK: 80,  outputK: 30, est: '$0.80' },
  integrate:        { model: 'haiku',  inputK: 40,  outputK: 6,  est: '$0.02' },
  synthesis_infra:  { model: 'haiku',  inputK: 30,  outputK: 6,  est: '$0.02' },
  prepare_release:  { model: 'haiku',  inputK: 20,  outputK: 4,  est: '$0.01' },
};

// Claude model IDs
const MODELS = {
  haiku:  'claude-haiku-4-5',
  sonnet: 'claude-sonnet-4-5',
};

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------
function log(msg) {
  const ts = new Date().toISOString();
  const line = `[${ts}] ${msg}`;
  console.log(line);
  fs.appendFileSync(LOG_FILE, line + '\n');
}

function logSection(title) {
  const bar = '='.repeat(60);
  log(bar);
  log(`  ${title}`);
  log(bar);
}

// ---------------------------------------------------------------------------
// Target loading / saving
// ---------------------------------------------------------------------------
function loadTargets() {
  const raw = fs.readFileSync(TARGETS_FILE, 'utf8');
  return JSON.parse(raw);
}

function saveTargets(data) {
  fs.writeFileSync(TARGETS_FILE, JSON.stringify(data, null, 2) + '\n');
}

// ---------------------------------------------------------------------------
// Filesystem state detection
//
// We infer "real" state by checking what exists on disk rather than trusting
// the JSON record.  This lets the orchestrator self-heal after manual work.
// ---------------------------------------------------------------------------

/**
 * Return the highest pipeline state that the filesystem evidence supports.
 */
function getState(target) {
  const abs = (rel) => path.join(REPO_ROOT, rel);

  // published: a RELEASE tag file or GitHub release marker
  const releaseMark = abs(`${target.integration_dir}/RELEASE`);
  if (fs.existsSync(releaseMark)) return 'published';

  // validated: a hardware sign-off file exists
  const validatedMark = abs(`${target.integration_dir}/HARDWARE_VALIDATED`);
  if (fs.existsSync(validatedMark)) return 'validated';

  // synthesized: quartus output_files/*.rbf exists
  const rbfGlob = abs(`${target.quartus_dir}/output_files`);
  if (fs.existsSync(rbfGlob)) {
    const files = fs.readdirSync(rbfGlob).filter(f => f.endsWith('.rbf'));
    if (files.length > 0) return 'synthesized';
  }

  // integrated: emu.sv or top-level .sv in quartus dir
  const emuSv = abs(`${target.quartus_dir}/emu.sv`);
  if (fs.existsSync(emuSv)) return 'integrated';

  // tests_passing: we run make to determine this live (see runTests)
  // Here we check that test vectors exist as a prerequisite
  const testDir = abs(target.test_dir);
  const rtlDir  = abs(target.rtl_dir);
  if (fs.existsSync(testDir) && fs.existsSync(rtlDir)) {
    const svFiles = safeReaddir(rtlDir).filter(f => f.endsWith('.sv'));
    const vecFiles = safeReaddir(testDir).filter(f => f.endsWith('.jsonl'));
    if (svFiles.length > 0 && vecFiles.length > 0) {
      // We have RTL + vectors: assume rtl_started until we test
      return 'rtl_started';
    }
  }

  // researched: research doc exists
  const researchDir = abs(target.research_dir);
  if (fs.existsSync(researchDir)) {
    const docs = safeReaddir(researchDir).filter(f =>
      f.endsWith('.md') || f.endsWith('.txt')
    );
    if (docs.length > 0) return 'researched';
  }

  return 'unresearched';
}

function safeReaddir(dir) {
  try { return fs.readdirSync(dir); }
  catch (_) { return []; }
}

// ---------------------------------------------------------------------------
// Test runner
// ---------------------------------------------------------------------------

/**
 * Run `make test` in the target's test directory.
 * Returns { passed: bool, output: string }.
 */
function runTests(target, dryRun = false) {
  const testDir = path.join(REPO_ROOT, target.test_dir);

  if (!fs.existsSync(testDir)) {
    return { passed: false, output: `Test directory not found: ${testDir}` };
  }

  const makefilePath = path.join(testDir, 'Makefile');
  if (!fs.existsSync(makefilePath)) {
    return { passed: false, output: `No Makefile in ${testDir}` };
  }

  if (dryRun) {
    return { passed: null, output: '[dry-run] would run: make test in ' + testDir };
  }

  log(`Running tests for ${target.id} in ${testDir}`);
  const result = spawnSync('make', ['test'], {
    cwd: testDir,
    encoding: 'utf8',
    timeout: 300_000, // 5 minutes
  });

  const output = (result.stdout || '') + (result.stderr || '');
  const passed = result.status === 0;
  return { passed, output };
}

// ---------------------------------------------------------------------------
// State update
// ---------------------------------------------------------------------------
function updateState(targetId, newState, dryRun = false) {
  if (dryRun) {
    log(`[dry-run] would update ${targetId} → ${newState}`);
    return;
  }

  const data = loadTargets();
  const t = data.targets.find(x => x.id === targetId);
  if (!t) throw new Error(`Target not found: ${targetId}`);

  const old = t.state;
  t.state = newState;
  saveTargets(data);
  log(`State updated: ${targetId} ${old} → ${newState}`);
}

// ---------------------------------------------------------------------------
// Prompt loading
// ---------------------------------------------------------------------------
function loadPrompt(task) {
  const promptPath = path.join(PROMPTS_DIR, `${task}.md`);
  if (!fs.existsSync(promptPath)) {
    throw new Error(`Prompt template not found: ${promptPath}`);
  }
  return fs.readFileSync(promptPath, 'utf8');
}

function renderPrompt(template, target) {
  // Simple token substitution
  return template
    .replace(/\{\{TARGET_ID\}\}/g, target.id)
    .replace(/\{\{TARGET_NAME\}\}/g, target.name)
    .replace(/\{\{GAMES\}\}/g, target.games.join(', '))
    .replace(/\{\{RESEARCH_DIR\}\}/g, target.research_dir)
    .replace(/\{\{RTL_DIR\}\}/g, target.rtl_dir)
    .replace(/\{\{TEST_DIR\}\}/g, target.test_dir)
    .replace(/\{\{INTEGRATION_DIR\}\}/g, target.integration_dir)
    .replace(/\{\{QUARTUS_DIR\}\}/g, target.quartus_dir)
    .replace(/\{\{NOTES\}\}/g, target.notes || '')
    .replace(/\{\{REPO_ROOT\}\}/g, REPO_ROOT);
}

// ---------------------------------------------------------------------------
// Agent dispatch
// ---------------------------------------------------------------------------

/**
 * Call the Claude API with the rendered prompt.
 * Returns the assistant response text.
 */
async function callAgent(agentKey, task, prompt, dryRun = false) {
  const cost = COST_ESTIMATES[task] || { est: 'unknown' };
  log(`Dispatching agent: ${agentKey} / task: ${task} / estimated cost: ${cost.est}`);

  if (dryRun) {
    log('[dry-run] skipping API call');
    return '[dry-run] no response';
  }

  const client = new Anthropic();
  const model  = MODELS[agentKey] || MODELS.haiku;

  const response = await client.messages.create({
    model,
    max_tokens: 8192,
    messages: [{ role: 'user', content: prompt }],
  });

  const text = response.content
    .filter(b => b.type === 'text')
    .map(b => b.text)
    .join('\n');

  // Log usage
  const usage = response.usage || {};
  log(`Agent done. tokens: in=${usage.input_tokens} out=${usage.output_tokens}`);

  return text;
}

// ---------------------------------------------------------------------------
// Core advance logic
// ---------------------------------------------------------------------------

/**
 * Advance a single target by one pipeline step.
 */
async function advanceTarget(target, dryRun = false) {
  const fsState = getState(target);

  // Sync JSON state to filesystem reality if behind
  if (STATES.indexOf(fsState) > STATES.indexOf(target.state)) {
    log(`${target.id}: filesystem state (${fsState}) ahead of JSON (${target.state}), syncing`);
    updateState(target.id, fsState, dryRun);
    target.state = fsState;
  }

  const currentState = target.state;
  const transition   = TRANSITIONS[currentState];

  if (!transition || transition.agent === 'none') {
    log(`${target.id}: already at terminal state (${currentState}), nothing to do`);
    return { advanced: false, reason: 'terminal' };
  }

  if (transition.agent === 'human') {
    log(`${target.id}: state=${currentState} requires human sign-off (hardware validation)`);
    log(`  To mark validated: create ${path.join(REPO_ROOT, target.integration_dir, 'HARDWARE_VALIDATED')}`);
    log(`  Or run: touch ${path.join(REPO_ROOT, target.integration_dir)}/HARDWARE_VALIDATED`);
    return { advanced: false, reason: 'awaiting_human' };
  }

  // Gate: tests must pass before advancing FROM rtl_started
  if (currentState === 'rtl_started') {
    const { passed, output } = runTests(target, dryRun);
    if (dryRun) {
      log(`[dry-run] ${output}`);
    } else if (!passed) {
      log(`${target.id}: tests FAILED — dispatching fix_tests agent`);
      // Fall through: still dispatch fix_tests (task is to fix the failures)
    } else {
      log(`${target.id}: tests PASS — advancing to tests_passing`);
      updateState(target.id, 'tests_passing', dryRun);
      target.state = 'tests_passing';
      // Re-evaluate with new state
      return advanceTarget(target, dryRun);
    }
  }

  // Load and render prompt
  const template = loadPrompt(transition.task);
  const prompt   = renderPrompt(template, target);

  // Dispatch
  const response = await callAgent(transition.agent, transition.task, prompt, dryRun);

  // Log response to a per-target file
  if (!dryRun) {
    const outDir  = path.join(REPO_ROOT, target.research_dir, 'orchestrator_outputs');
    if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
    const outFile = path.join(outDir, `${transition.task}_${Date.now()}.md`);
    fs.writeFileSync(outFile, `# ${transition.task} — ${target.id}\n\n${response}\n`);
    log(`Response saved: ${outFile}`);
  }

  // For tasks where the agent's response IS the advancement (research, integrate,
  // synthesis_infra, prepare_release) we trust the output and advance state.
  // For write_rtl and fix_tests, the agent creates files on disk; state advances
  // when the next run detects those files + passing tests.
  const autoAdvanceTasks = new Set(['research', 'integrate', 'synthesis_infra']);

  if (!dryRun && autoAdvanceTasks.has(transition.task)) {
    updateState(target.id, transition.nextState, dryRun);
    log(`${target.id}: auto-advanced to ${transition.nextState}`);
  } else {
    log(`${target.id}: agent completed. Re-run orchestrator after reviewing output to detect state change.`);
  }

  return { advanced: true, task: transition.task, response };
}

// ---------------------------------------------------------------------------
// Status report
// ---------------------------------------------------------------------------
function printStatus(targets) {
  logSection('Pipeline Status');
  const maxIdLen = Math.max(...targets.map(t => t.id.length));

  for (const t of targets) {
    const fsState   = getState(t);
    const staleFlag = fsState !== t.state ? ` [JSON:${t.state}]` : '';
    const bar       = buildStateBar(fsState);
    const padId     = t.id.padEnd(maxIdLen);
    log(`  ${padId}  ${fsState.padEnd(14)}${staleFlag}  ${bar}`);
  }
}

function buildStateBar(state) {
  const idx = STATES.indexOf(state);
  const filled = '█'.repeat(idx + 1);
  const empty  = '░'.repeat(STATES.length - idx - 1);
  return `[${filled}${empty}]`;
}

// ---------------------------------------------------------------------------
// CLI entry point
// ---------------------------------------------------------------------------
async function main() {
  const argv   = process.argv.slice(2);
  const dryRun  = argv.includes('--dry-run');
  const all     = argv.includes('--all');
  const status  = argv.includes('--status');
  const publish = argv.includes('--publish');

  const targetArg = (() => {
    const i = argv.indexOf('--target');
    return i >= 0 ? argv[i + 1] : null;
  })();

  const publishArg = (() => {
    const i = argv.indexOf('--publish');
    return i >= 0 ? argv[i + 1] : null;
  })();

  if (dryRun) log('DRY-RUN MODE — no API calls, no file writes, no state changes');

  const data    = loadTargets();
  const targets = data.targets;

  // --status: just show pipeline state
  if (status) {
    printStatus(targets);
    return;
  }

  // --publish <id>: explicitly advance validated → published
  if (publishArg) {
    const t = targets.find(x => x.id === publishArg);
    if (!t) { log(`Unknown target: ${publishArg}`); process.exit(1); }
    if (t.state !== 'validated') {
      log(`${publishArg} is not in validated state (current: ${t.state})`);
      process.exit(1);
    }
    log(`Publishing ${publishArg} — running prepare_release agent`);
    const result = await advanceTarget(t, dryRun);
    log(JSON.stringify(result, null, 2));
    return;
  }

  // Resolve which targets to work on
  let workList;
  if (targetArg) {
    const t = targets.find(x => x.id === targetArg);
    if (!t) { log(`Unknown target: ${targetArg}`); process.exit(1); }
    workList = [t];
  } else if (all) {
    // Sort by priority ascending, skip terminal states
    workList = targets
      .filter(t => t.state !== 'published')
      .sort((a, b) => a.priority - b.priority);
  } else {
    // Default: show status and exit with usage hint
    printStatus(targets);
    console.log('');
    console.log('Usage:');
    console.log('  node orchestrator.js --status');
    console.log('  node orchestrator.js --target <id> [--dry-run]');
    console.log('  node orchestrator.js --all [--dry-run]');
    console.log('  node orchestrator.js --publish <id>');
    return;
  }

  // Run
  for (const t of workList) {
    logSection(`Processing: ${t.id} (priority ${t.priority})`);

    // validated → published requires explicit --publish flag
    if (t.state === 'validated' && !publish) {
      log(`${t.id}: state=validated. Use --publish ${t.id} to create a release.`);
      continue;
    }

    // synthesized → validated requires human sign-off (no agent dispatch)
    if (t.state === 'synthesized') {
      log(`${t.id}: state=synthesized. Hardware validation required before pipeline can advance.`);
      log(`  Sign-off procedure:`);
      log(`    1. Flash ${t.id}.rbf to DE-10 Nano`);
      log(`    2. Verify at least one game boots`);
      log(`    3. Run: touch ${path.join(REPO_ROOT, t.integration_dir)}/HARDWARE_VALIDATED`);
      log(`    4. Re-run orchestrator`);
      continue;
    }

    try {
      const result = await advanceTarget(t, dryRun);
      log(`Result: ${JSON.stringify(result)}`);
    } catch (err) {
      log(`ERROR processing ${t.id}: ${err.message}`);
      if (err.stack) log(err.stack);
      // Don't abort the whole run on a single target error
    }
  }

  logSection('Done');
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
