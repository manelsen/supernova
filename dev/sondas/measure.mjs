import { chromium, webkit } from 'playwright';
const [engine, mode, nStr] = process.argv.slice(2);
const N = Number(nStr || 7);
const PAGES = [
  'https://pt.wikipedia.org/wiki/Brasil',
  'https://g1.globo.com/',
  'https://github.com/microsoft/playwright',
  'https://www.mercadolivre.com.br/',
  'https://www.uol.com.br/',
  'https://www.bbc.com/news',
  'https://stackoverflow.com/questions',
];
const type = engine === 'webkit' ? webkit : chromium;
const launch = () => type.launch({ headless: true });
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const t0 = Date.now();
let shared = mode === 'contexts' ? await launch() : null;
console.log(`READY 0 browser-only ${shared ? 'shared' : 'none'}`);
await sleep(8000);
const keep = [];
for (let i = 0; i < N; i++) {
  const url = PAGES[i % PAGES.length];
  const browser = shared ?? await launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await ctx.newPage();
  let note = '';
  const s = Date.now();
  try {
    await page.goto(url, { waitUntil: 'load', timeout: 45000 });
    await sleep(3000);
    const shot = await page.screenshot();
    const aria = await page.locator('body').ariaSnapshot({ timeout: 10000 });
    note = `ok load=${Date.now() - s}ms shot=${shot.length}B aria=${aria.length}ch`;
  } catch (e) {
    note = 'ERR ' + String(e.message).split('\n')[0].slice(0, 120);
  }
  keep.push({ browser, ctx });
  console.log(`READY ${i + 1} ${url} ${note}`);
  await sleep(8000);
}
console.log(`DONE ${Date.now() - t0}ms`);
await sleep(3000);
process.exit(0);
