// Running a shell command and collecting what it says, with a time limit
// that kills its whole process group. Used by the launcher (as user sh) and,
// outside the image, by the service itself.

import { spawn } from 'node:child_process';

export const SHELL_LIMITS = {
  outputChars: 20_000,
  execDefaultS: 60,
  execMaxS: 300,
};

export function clip(text, max) {
  if (text.length <= max) return { text, truncated: false };
  return { text: text.slice(0, max), truncated: true };
}

const LIMITS = SHELL_LIMITS;

export function runAs(command, timeoutS, { cwd, env, uid, gid }) {
  const limit = Math.min(Math.max(Number(timeoutS) || LIMITS.execDefaultS, 1), LIMITS.execMaxS);
  return new Promise((resolve) => {
    const child = spawn('bash', ['-lc', command], {
      cwd,
      env,
      uid,
      gid,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    const cap = LIMITS.outputChars * 2;
    // Decode as UTF-8 across chunk boundaries.
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (d) => { if (stdout.length < cap) stdout += d; });
    child.stderr.on('data', (d) => { if (stderr.length < cap) stderr += d; });
    const timer = setTimeout(() => {
      timedOut = true;
      try { process.kill(-child.pid, 'SIGKILL'); } catch { /* already gone */ }
    }, limit * 1000);
    // Resolve when the command itself ends, not when every process that
    // inherited its output does: a server started in the background
    // (`nohup ... &`) keeps running and must not hold the answer.
    let settled = false;
    const finish = (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.stdout.destroy();
      child.stderr.destroy();
      const out = clip(stdout, LIMITS.outputChars);
      const err = clip(stderr, LIMITS.outputChars);
      resolve({
        exit_code: code === null ? -1 : code,
        signal: signal || null,
        timed_out: timedOut,
        stdout: out.text,
        stderr: err.text,
        truncated: out.truncated || err.truncated,
      });
    };
    child.on('exit', (code, signal) => setTimeout(() => finish(code, signal), 100));
    child.on('close', (code, signal) => finish(code, signal));
    child.on('error', (e) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ exit_code: -1, signal: null, timed_out: false, stdout: '', stderr: String(e.message), truncated: false });
    });
  });
}

