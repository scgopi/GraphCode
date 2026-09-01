import { chromium } from 'playwright-core';
import { resolve } from 'node:path';
const [file, ...times] = process.argv.slice(2);
const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage({ viewport:{width:1200,height:675}, deviceScaleFactor:2, colorScheme:'dark' });
const errs = [];
page.on('pageerror', e => errs.push(String(e)));
page.on('console', m => { if (m.type()==='error') errs.push(m.text()); });
await page.goto('file://' + resolve(file));
await page.waitForFunction(() => typeof window.__seek === 'function');
await page.evaluate(() => window.__pause());
for (const t of times) {
  await page.evaluate(v => window.__seek(v), Number(t));
  await page.screenshot({ path: `probe-${t}.png` });
}
await browser.close();
console.log(errs.length ? 'ERRORS:\n' + errs.join('\n') : 'no console errors');
