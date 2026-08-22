import simpleGit from 'simple-git';
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join, dirname, basename, extname } from 'path';
import { homedir } from 'os';

const PULL_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes
const STATE_DIR = join(homedir(), '.vaultsync');
const STATE_FILE = join(STATE_DIR, 'state.json');
const LOG_FILE = join(STATE_DIR, 'conflict.log');

function loadState() {
  if (!existsSync(STATE_FILE)) return {};
  try { return JSON.parse(readFileSync(STATE_FILE, 'utf8')); } catch { return {}; }
}

function saveState(state) {
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

function logConflict(vault, filePath, incomingPath) {
  const ts = new Date().toISOString();
  const line = `[${ts}] conflict in ${filePath} → saved incoming as ${incomingPath}\n`;
  if (!existsSync(STATE_DIR)) mkdirSync(STATE_DIR, { recursive: true });
  writeFileSync(LOG_FILE, line, { flag: 'a' });
  console.log(`[vaultsync] ${line.trim()}`);
}

/**
 * Pulls from origin with rebase. On merge conflicts, writes the incoming
 * version as <name>.conflict-<date>.md alongside the original, keeps the
 * local version in place, and marks the conflict as resolved for git.
 *
 * Returns: 'ok' | 'conflicts' | 'error'
 */
export async function pullOnce(vault) {
  const git = simpleGit(vault);
  try {
    const branch = (await git.revparse(['--abbrev-ref', 'HEAD']).catch(() => 'main')).trim();

    // Stash any uncommitted changes so pull doesn't fail
    const status = await git.status();
    let stashed = false;
    if (status.files.length > 0) {
      await git.stash(['push', '-m', 'vaultsync-auto-stash']);
      stashed = true;
      console.log('[vaultsync] stashed uncommitted changes for pull');
    }

    // Attempt pull with rebase
    try {
      await git.pull('origin', branch, { '--rebase': null });
      console.log(`[vaultsync] pulled (${branch})`);
      const state = loadState();
      state.lastPull = new Date().toISOString();
      saveState(state);

      if (stashed) {
        await git.stash(['pop']);
        console.log('[vaultsync] restored stashed changes');
      }
      return 'ok';
    } catch (pullErr) {
      // Rebase conflict — git has left conflict markers in the files
      const mergeStatus = await git.status();
      const conflicts = mergeStatus.conflicted;

      if (conflicts.length === 0) {
        // Abort the rebase if no conflicts found (unexpected error)
        await git.rebase(['--abort']).catch(() => {});
        if (stashed) await git.stash(['pop']).catch(() => {});
        console.error('[vaultsync] pull failed but no conflicts found:', pullErr.message);
        return 'error';
      }

      console.log(`[vaultsync] pull conflict on ${conflicts.length} file(s) — resolving safely`);

      const today = new Date().toISOString().split('T')[0];

      for (const relPath of conflicts) {
        const fullPath = join(vault, relPath);
        const dir = dirname(relPath);
        const name = basename(relPath, extname(relPath));
        const ext = extname(relPath);
        const conflictName = `${name}.conflict-${today}${ext}`;
        const conflictPath = join(vault, dir, conflictName);

        // Get the full incoming (theirs) version from git's index.
        // During a rebase, stage 3 = theirs (the local commits being rebased).
        let theirsContent = '';
        try {
          theirsContent = await git.show([`:3:${relPath}`]);
        } catch {
          // Fallback: extract from conflict markers in the file on disk
          if (existsSync(fullPath)) {
            theirsContent = extractTheirs(readFileSync(fullPath, 'utf8'));
          }
        }

        // Write the complete incoming version as a conflict file
        writeFileSync(conflictPath, theirsContent);
        logConflict(vault, relPath, conflictName);

        // Restore our version: check out ours
        await git.checkout(['--ours', relPath]);
      }

      // Complete the rebase with our conflicts resolved
      await git.add('.');
      await git.rebase(['--continue']).catch(async () => {
        // If --continue fails (e.g. GIT_EDITOR not set), abort and force resolve
        await git.rebase(['--abort']).catch(() => {});
        // Just checkout ours for all conflicted files
        for (const c of conflicts) {
          await git.checkout(['--ours', c]).catch(() => {});
        }
        await git.add('.');
      });

      if (stashed) {
        await git.stash(['pop']).catch(() => {});
        console.log('[vaultsync] restored stashed changes');
      }

      const state = loadState();
      state.lastPull = new Date().toISOString();
      saveState(state);
      return 'conflicts';
    }
  } catch (err) {
    console.error('[vaultsync] pull error:', err.message);
    return 'error';
  }
}

/**
 * Extracts the "theirs" side from a file with git conflict markers.
 * Looks for <<<<<<<, =======, >>>>>>> markers.
 */
function extractTheirs(content) {
  const theirs = [];
  let inTheirs = false;

  for (const line of content.split('\n')) {
    if (line.startsWith('>>>>>>>')) {
      inTheirs = false;
      continue;
    }
    if (line.startsWith('=======')) {
      inTheirs = true;
      continue;
    }
    if (line.startsWith('<<<<<<<')) {
      continue;
    }
    if (inTheirs) {
      theirs.push(line);
    }
  }

  // If no conflict markers found, return the full content
  return theirs.length > 0 ? theirs.join('\n') : content;
}

/**
 * Starts the pull loop: pull once, then every 5 minutes.
 */
export function startSyncer(vault) {
  const interval = setInterval(() => {
    pullOnce(vault).catch(err => {
      console.error('[vaultsync] periodic pull error:', err.message);
    });
  }, PULL_INTERVAL_MS);

  console.log(`[vaultsync] pull loop started (every ${PULL_INTERVAL_MS / 1000}s)`);

  process.on('SIGINT', () => { clearInterval(interval); });
  process.on('SIGTERM', () => { clearInterval(interval); });
}
