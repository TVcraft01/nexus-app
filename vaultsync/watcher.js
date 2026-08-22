import { watch } from 'chokidar';
import simpleGit from 'simple-git';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

const DEBOUNCE_MS = 30_000;
const STATE_DIR = join(homedir(), '.vaultsync');
const STATE_FILE = join(STATE_DIR, 'state.json');

function loadState() {
  if (!existsSync(STATE_FILE)) return {};
  try { return JSON.parse(readFileSync(STATE_FILE, 'utf8')); } catch { return {}; }
}

function saveState(state) {
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

/**
 * Starts watching [vault] for changes. After 30 seconds of quiet, commits
 * everything and pushes. Ignores .git, .obsidian/workspace*, .trash.
 */
export function startWatcher(vault) {
  const git = simpleGit(vault);
  let timer = null;
  let pushing = false;

  const watcher = watch(vault, {
    ignored: [
      /(^|[\/\\])\.git($|[\/\\])/,
      /(^|[\/\\])\.obsidian[\/\\]workspace/,
      /(^|[\/\\])\.trash($|[\/\\])/,
      /(^|[\/\\])node_modules($|[\/\\])/,
    ],
    persistent: true,
    ignoreInitial: true,
    awaitWriteFinish: {
      stabilityThreshold: 2000,
      pollInterval: 500,
    },
  });

  function scheduleCommit() {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => commitAndPush(), DEBOUNCE_MS);
  }

  async function commitAndPush() {
    if (pushing) return;
    pushing = true;

    try {
      const status = await git.status();

      // Nothing to commit
      if (status.files.length === 0 && status.conflicted.length === 0) {
        pushing = false;
        return;
      }

      // If there are unresolved conflicts, don't commit — they need manual
      // resolution first. The syncer already wrote the .conflict- files.
      if (status.conflicted.length > 0) {
        console.log(`[vaultsync] ${status.conflicted.length} unresolved conflict(s) — skipping commit. Resolve or accept incoming.`);
        pushing = false;
        return;
      }

      await git.add('.');
      const msg = `vaultsync: auto-commit ${status.files.length} file(s)`;
      await git.commit(msg);
      console.log(`[vaultsync] committed: ${msg}`);

      // Try to push; if it fails (diverged history), pull with rebase first
      try {
        await git.push();
        console.log('[vaultsync] pushed.');
        const state = loadState();
        state.lastPush = new Date().toISOString();
        saveState(state);
      } catch (pushErr) {
        console.log('[vaultsync] push rejected, pulling with rebase…');
        const branch = (await git.revparse(['--abbrev-ref', 'HEAD']).catch(() => 'main')).trim();
        await git.pull('origin', branch, { '--rebase': null });
        await git.push(['-u', 'origin', branch]);
        console.log('[vaultsync] rebased and pushed.');
        const state = loadState();
        state.lastPush = new Date().toISOString();
        saveState(state);
      }
    } catch (err) {
      console.error('[vaultsync] commit/push error:', err.message);
    } finally {
      pushing = false;
    }
  }

  watcher.on('add', scheduleCommit);
  watcher.on('change', scheduleCommit);
  watcher.on('unlink', scheduleCommit);
  watcher.on('addDir', scheduleCommit);
  watcher.on('unlinkDir', scheduleCommit);

  console.log('[vaultsync] watcher started — will commit 30s after last change');

  // Commit any pending changes that existed before the watcher started
  // (e.g. stashed changes restored during the pull-on-start cycle).
  // ignoreInitial: true means chokidar won't see these.
  git.status().then(status => {
    if (status.files.length > 0) {
      console.log(`[vaultsync] ${status.files.length} pending change(s) from before watcher started`);
      scheduleCommit();
    }
  }).catch(() => {});

  // Graceful shutdown
  process.on('SIGINT', () => { watcher.close(); });
  process.on('SIGTERM', () => { watcher.close(); });
}
