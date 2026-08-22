#!/usr/bin/env node

import { resolve, join, dirname } from 'path';
import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync } from 'fs';
import { homedir } from 'os';
import { fileURLToPath } from 'url';

import simpleGit from 'simple-git';

import { startWatcher } from './watcher.js';
import { startSyncer, pullOnce } from './syncer.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

const STATE_DIR = join(homedir(), '.vaultsync');
const STATE_FILE = join(STATE_DIR, 'state.json');

function loadState() {
  if (!existsSync(STATE_DIR)) mkdirSync(STATE_DIR, { recursive: true });
  if (!existsSync(STATE_FILE)) return {};
  try { return JSON.parse(readFileSync(STATE_FILE, 'utf8')); } catch { return {}; }
}

function saveState(state) {
  if (!existsSync(STATE_DIR)) mkdirSync(STATE_DIR, { recursive: true });
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

function resolveVault(vaultArg) {
  if (vaultArg) return resolve(vaultArg);
  const state = loadState();
  if (state.defaultVault) return resolve(state.defaultVault);
  console.error('No vault path given and no default set.\nUsage: vaultsync <init|start|stop|status> <vault-path>');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

async function cmdInit(vaultPath, repoUrl) {
  const vault = resolve(vaultPath);
  if (!existsSync(vault)) {
    console.error(`Vault path does not exist: ${vault}`);
    process.exit(1);
  }

  const git = simpleGit(vault);
  const isRepo = await git.checkIsRepo();

  if (!isRepo) {
    console.log('Initialising git repo…');
    await git.init();
  }

  // Install the .gitignore for Obsidian
  const giTemplate = join(__dirname, '.gitignore.template');
  const giTarget = join(vault, '.gitignore');
  if (existsSync(giTemplate) && !existsSync(giTarget)) {
    writeFileSync(giTarget, readFileSync(giTemplate, 'utf8'));
    console.log('Wrote .gitignore (Obsidian workspace/trash excluded).');
  }

  if (repoUrl) {
    const remotes = await git.getRemotes(true);
    const origin = remotes.find(r => r.name === 'origin');
    if (!origin) {
      console.log(`Adding remote origin → ${repoUrl}`);
      await git.addRemote('origin', repoUrl);
    } else if (origin.refs.fetch !== repoUrl) {
      console.log(`Updating remote origin → ${repoUrl}`);
      await git.remote(['set-url', 'origin', repoUrl]);
    }
  }

  // Ensure upstream tracking is set for the current branch
  const remotes = await git.getRemotes(true);
  const hasOrigin = remotes.some(r => r.name === 'origin');
  if (hasOrigin) {
    const branch = (await git.revparse(['--abbrev-ref', 'HEAD']).catch(() => 'main')).trim();
    const tracking = await git.raw(['branch', '--show-tracking']).catch(() => '');
    if (!tracking.includes('origin/')) {
      await git.push(['-u', 'origin', branch]).catch(() => {});
    }
  }

  // Initial commit if there's nothing committed yet
  const log = await git.log({ maxCount: 1 }).catch(() => null);
  if (!log || log.total === 0) {
    await git.add('.');
    await git.commit('vaultsync: initial commit');
    console.log('Created initial commit.');
    if (hasOrigin) {
      const branch = (await git.revparse(['--abbrev-ref', 'HEAD']).catch(() => 'main')).trim();
      await git.push(['-u', 'origin', branch]);
      console.log('Pushed initial commit.');
    }
  }

  // Set this as the default vault
  const state = loadState();
  state.defaultVault = vault;
  saveState(state);

  console.log(`\nVault synced at: ${vault}`);
  console.log('Next: vaultsync start');
}

async function cmdStart(vaultPath) {
  const vault = resolveVault(vaultPath);
  if (!existsSync(join(vault, '.git'))) {
    console.error(`Not a git repo: ${vault}\nRun "vaultsync init" first.`);
    process.exit(1);
  }

  // Write PID file so stop works. Check for existing instance first.
  const pidFile = join(STATE_DIR, 'vaultsync.pid');
  if (!existsSync(STATE_DIR)) mkdirSync(STATE_DIR, { recursive: true });
  if (existsSync(pidFile)) {
    const existingPid = parseInt(readFileSync(pidFile, 'utf8').trim(), 10);
    try { process.kill(existingPid, 0); 
      console.error(`vaultsync is already running (PID ${existingPid}). Stop it first.`);
      process.exit(1);
    } catch { /* stale PID file, ok to overwrite */ }
  }
  writeFileSync(pidFile, String(process.pid));

  const state = loadState();
  state.defaultVault = vault;
  state.startedAt = new Date().toISOString();
  saveState(state);

  console.log(`vaultsync watching: ${vault}`);
  console.log(`PID: ${process.pid}`);

  // Pull once on start
  await pullOnce(vault);

  // Start the pull loop (every 5 minutes)
  startSyncer(vault);

  // Start the file watcher (debounced auto-commit + push)
  startWatcher(vault);

  // Keep the process alive
  process.on('SIGINT', () => { console.log('\nStopping vaultsync…'); process.exit(0); });
  process.on('SIGTERM', () => process.exit(0));
}

async function cmdStop() {
  const pidFile = join(STATE_DIR, 'vaultsync.pid');
  if (!existsSync(pidFile)) {
    console.log('vaultsync is not running (no PID file).');
    return;
  }
  const pid = parseInt(readFileSync(pidFile, 'utf8').trim(), 10);
  try {
    process.kill(pid, 'SIGTERM');
    console.log(`Sent SIGTERM to vaultsync (PID ${pid}).`);
  } catch {
    console.log(`PID ${pid} was not running (stale PID file).`);
  }
  unlinkSync(pidFile);
}

async function cmdStatus(vaultPath) {
  const vault = resolveVault(vaultPath);

  // Check if vaultsync is running
  const pidFile = join(STATE_DIR, 'vaultsync.pid');
  let running = false;
  if (existsSync(pidFile)) {
    const pid = parseInt(readFileSync(pidFile, 'utf8').trim(), 10);
    try { process.kill(pid, 0); running = true; } catch { /* not running */ }
  }

  console.log(`Vault:    ${vault}`);
  console.log(`Running:  ${running ? 'yes (PID ' + readFileSync(pidFile, 'utf8').trim() + ')' : 'no'}`);

  if (!existsSync(join(vault, '.git'))) {
    console.log('Git:      not initialised');
    return;
  }

  const git = simpleGit(vault);

  // Branch and remote
  const branch = await git.revparse(['--abbrev-ref', 'HEAD']).catch(() => 'unknown');
  console.log(`Branch:   ${branch.trim()}`);

  const remotes = await git.getRemotes(true);
  const origin = remotes.find(r => r.name === 'origin');
  console.log(`Remote:   ${origin ? origin.refs.fetch : '(none)'}`);

  // Last commit
  const log = await git.log({ maxCount: 1 }).catch(() => null);
  if (log && log.latest) {
    console.log(`Last commit: ${log.latest.date} — ${log.latest.message}`);
  }

  // Uncommitted changes
  const status = await git.status();
  const changes = status.files.length;
  console.log(`Uncommitted changes: ${changes}`);
  if (changes > 0) {
    for (const f of status.files) {
      console.log(`  ${f.index}${f.working_dir} ${f.path}`);
    }
  }

  // Conflict files
  const conflicts = status.conflicted;
  if (conflicts.length > 0) {
    console.log(`\nConflict files (${conflicts.length}):`);
    for (const c of conflicts) {
      console.log(`  ⚠  ${c}`);
    }
  }

  // State info
  const state = loadState();
  if (state.lastPush) console.log(`Last push:  ${state.lastPush}`);
  if (state.lastPull) console.log(`Last pull:  ${state.lastPull}`);
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const [,, cmd, ...args] = process.argv;

switch (cmd) {
  case 'init':
    if (args.length < 1) {
      console.error('Usage: vaultsync init <vault-path> [repo-url]');
      process.exit(1);
    }
    await cmdInit(args[0], args[1]);
    break;

  case 'start':
    await cmdStart(args[0]);
    break;

  case 'stop':
    await cmdStop();
    break;

  case 'status':
    await cmdStatus(args[0]);
    break;

  default:
    console.log(`
vaultsync — git-based Obsidian vault sync

Commands:
  vaultsync init  <vault-path> [repo-url]   Initialise a vault for syncing
  vaultsync start [vault-path]              Start watcher + sync loop
  vaultsync stop                            Stop the running watcher
  vaultsync status [vault-path]             Show sync state and conflicts

Examples:
  vaultsync init ~/ObsidianVault git@github.com:user/vault.git
  vaultsync start
  vaultsync status
`);
}
