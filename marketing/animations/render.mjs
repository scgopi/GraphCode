// Frame-capture for the article animations.
//
//   node render.mjs <file.html> <out-dir> [fps] [width] [height]
//
// Each animation exposes `window.__seek(t)` and `window.__duration`, so frames are
// stepped rather than recorded in real time: the capture is deterministic and the GIF
// can never drift from the HTML it came from.
import { chromium } from 'playwright-core';
import { mkdir, rm } from 'node:fs/promises';
import { resolve } from 'node:path';

const [file, outDir, fpsArg, wArg, hArg] = process.argv.slice(2);
if (!file || !outDir) {
  console.error('usage: node render.mjs <file.html> <out-dir> [fps] [width] [height]');
  process.exit(1);
}

const fps = Number(fpsArg ?? 25);
const width = Number(wArg ?? 1200);
const height = Number(hArg ?? 760);

await rm(outDir, { recursive: true, force: true });
await mkdir(outDir, { recursive: true });

const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage({
  viewport: { width, height },
  deviceScaleFactor: 2,
  colorScheme: 'dark',
});
await page.goto('file://' + resolve(file));
await page.waitForFunction(() => typeof window.__seek === 'function');
await page.evaluate(() => window.__pause());

const duration = await page.evaluate(() => window.__duration);
const frames = Math.round(duration * fps);
for (let i = 0; i < frames; i++) {
  await page.evaluate(t => window.__seek(t), i / fps);
  await page.screenshot({ path: `${outDir}/f${String(i).padStart(4, '0')}.png` });
}
await browser.close();
console.log(`${frames} frames @ ${fps}fps (${duration}s) → ${outDir}`);
