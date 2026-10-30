// Renders docs/showcase.html, the animated picture of Boardwalk at work, into
// docs/showcase.mp4 and docs/showcase.webp, an animated image the README shows
// (GitHub plays no video kept in the repo). Each frame is drawn at its exact
// moment in headless Chrome, so nothing depends on the screen or timing.
// Needs Google Chrome, ffmpeg and img2webp (brew install ffmpeg webp).
//   node scripts/render-showcase.mjs
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(import.meta.dirname, '..');
const page = `${pathToFileURL(join(root, 'docs/showcase.html')).href}#film`;
const chromePath = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
// The page's loop, and the screen it draws (1280 × 800), drawn at 1.5×.
const seconds = 27.8, fps = 60, scale = 1.5;

const work = mkdtempSync(join(tmpdir(), 'showcase-'));
const port = 9300 + Math.floor(Math.random() * 500);
const chrome = spawn(chromePath, [
  '--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${join(work, 'profile')}`,
  '--hide-scrollbars', 'about:blank',
], { stdio: 'ignore' });

try {
  const cdp = await connect(await pageTarget());
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: scale, mobile: false });
  await cdp('Page.enable');
  const loaded = cdp.next('Page.loadEventFired');
  await cdp('Page.navigate', { url: page });
  await loaded;
  await evaluate(cdp, 'document.fonts.ready.then(() => true)');

  const frames = Math.round(seconds * fps);
  for (let i = 0; i < frames; i++) {
    await evaluate(cdp, `renderAt(${i / fps})`);
    const { data } = await cdp('Page.captureScreenshot', { format: 'png' });
    writeFileSync(join(work, `f${String(i).padStart(5, '0')}.png`), Buffer.from(data, 'base64'));
    if (i % fps === 0) process.stdout.write(`\rframes ${i}/${frames}`);
  }
  process.stdout.write(`\rframes ${frames}/${frames}\n`);

  const ffmpeg = (...args) => execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args], { stdio: 'inherit' });
  ffmpeg('-framerate', String(fps), '-i', join(work, 'f%05d.png'),
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
    join(root, 'docs/showcase.mp4'));

  // The animated image: half the frames, at 960 wide, which is as wide as GitHub shows it.
  ffmpeg('-framerate', String(fps), '-i', join(work, 'f%05d.png'), '-vf', 'fps=30,scale=960:-1:flags=lanczos', join(work, 'w%04d.png'));
  const small = readdirSync(work).filter((name) => /^w\d+\.png$/.test(name)).sort().map((name) => join(work, name));
  execFileSync('img2webp', ['-loop', '0', '-lossy', '-q', '72', '-m', '6', '-d', '33', ...small, '-o', join(root, 'docs/showcase.webp')], { stdio: 'inherit' });
  console.log('Wrote docs/showcase.mp4 and docs/showcase.webp');
} finally {
  chrome.kill();
  rmSync(work, { recursive: true, force: true });
}

/** The DevTools address of Chrome's first page, once Chrome is listening. */
async function pageTarget() {
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      const target = targets.find((t) => t.type === 'page');
      if (target) return target.webSocketDebuggerUrl;
    } catch { /* not listening yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('Chrome did not start');
}

/** A DevTools connection: cdp(method, params) sends a command, cdp.next(event) waits for an event. */
function connect(url) {
  const socket = new WebSocket(url);
  const replies = new Map(), events = new Map();
  let id = 0;
  socket.onmessage = ({ data }) => {
    const message = JSON.parse(data);
    if (message.id) {
      const reply = replies.get(message.id);
      replies.delete(message.id);
      if (message.error) reply.reject(new Error(message.error.message));
      else reply.resolve(message.result);
    } else if (events.has(message.method)) {
      events.get(message.method)(message.params);
      events.delete(message.method);
    }
  };
  const cdp = (method, params = {}) => new Promise((resolve, reject) => {
    replies.set(++id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });
  cdp.next = (method) => new Promise((resolve) => events.set(method, resolve));
  return new Promise((resolve, reject) => {
    socket.onopen = () => resolve(cdp);
    socket.onerror = () => reject(new Error(`can't connect to ${url}`));
  });
}

/** Runs JavaScript in the page, failing if it throws. */
async function evaluate(cdp, expression) {
  const { exceptionDetails } = await cdp('Runtime.evaluate', { expression, awaitPromise: true });
  if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
}
