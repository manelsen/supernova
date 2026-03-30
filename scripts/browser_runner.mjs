import fs from "node:fs";
import readline from "node:readline";
import { chromium } from "playwright-core";

const executablePath = resolveExecutablePath();

let browser;
let context;
let page;
let closing = false;

start().catch((error) => {
  writeError(error);
  process.exit(1);
});

async function start() {
  browser = await chromium.launch({
    executablePath,
    headless: true,
    args: ["--no-sandbox", "--disable-dev-shm-usage"],
  });
  context = await browser.newContext();
  page = await context.newPage();

  const rl = readline.createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
    terminal: false,
  });

  rl.on("line", async (line) => {
    if (closing) {
      return;
    }

    rl.pause();

    try {
      const command = JSON.parse(line);
      const result = await handleCommand(command);
      writeJson(result);

      if (command.op === "close") {
        closing = true;
        await shutdown();
        process.exit(0);
      }
    } catch (error) {
      writeError(error);
    } finally {
      if (!closing) {
        rl.resume();
      }
    }
  });

  rl.on("close", async () => {
    closing = true;
    await shutdown();
    process.exit(0);
  });
}

async function handleCommand(command) {
  const timeout = normalizeTimeout(command.timeout_ms);

  switch (command.op) {
    case "open":
      assertString(command.url, "url");
      await withTimeout(
        timeout,
        page.goto(command.url, {
          waitUntil: "domcontentloaded",
          timeout,
        }),
      );
      return {
        title: await page.title(),
        url: page.url(),
      };

    case "click":
      assertString(command.selector, "selector");
      await withTimeout(
        timeout,
        page.click(command.selector, { timeout }),
      );
      return { ok: true, url: page.url() };

    case "type":
      assertString(command.selector, "selector");
      assertString(command.text, "text");
      await withTimeout(
        timeout,
        page.locator(command.selector).fill(command.text, { timeout }),
      );
      return { ok: true };

    case "evaluate":
      assertString(command.script, "script");
      return {
        value: await withTimeout(
          timeout,
          page.evaluate((script) => globalThis.eval(script), command.script),
        ),
      };

    case "extract_readable": {
      const text = await withTimeout(
        timeout,
        page.evaluate(() => {
          const root =
            document.querySelector("main, article, [role='main']") ||
            document.body;
          return (root.innerText || root.textContent || "")
            .replace(/\r/g, "")
            .replace(/\n{3,}/g, "\n\n")
            .trim();
        }),
      );

      return {
        title: await page.title(),
        text,
      };
    }

    case "screenshot": {
      const buffer = await withTimeout(
        timeout,
        page.screenshot({
          type: "png",
          fullPage: true,
          timeout,
        }),
      );

      return {
        mime_type: "image/png",
        data_base64: buffer.toString("base64"),
      };
    }

    case "close":
      return { closed: true };

    default:
      throw new Error(`Unsupported browser op: ${String(command.op)}`);
  }
}

async function shutdown() {
  try {
    if (page) {
      await page.close();
    }
  } catch {}

  try {
    if (context) {
      await context.close();
    }
  } catch {}

  try {
    if (browser) {
      await browser.close();
    }
  } catch {}
}

function resolveExecutablePath() {
  const explicit = process.env.SUPERNOVA_BROWSER_EXECUTABLE;
  if (explicit && fs.existsSync(explicit)) {
    return explicit;
  }

  const candidates = [
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ];

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  throw new Error("No supported browser executable found");
}

function normalizeTimeout(value) {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    return Math.floor(value);
  }

  return 5000;
}

async function withTimeout(timeoutMs, promise) {
  let timeoutId;

  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timeoutId = setTimeout(() => {
          reject(new Error(`Timed out after ${timeoutMs}ms`));
        }, timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timeoutId);
  }
}

function assertString(value, field) {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`Missing ${field}`);
  }
}

function writeJson(value) {
  const normalized =
    value === undefined ? null : value;
  process.stdout.write(`${JSON.stringify(normalized)}\n`);
}

function writeError(error) {
  const message =
    error instanceof Error ? error.message : String(error);
  process.stdout.write(`ERROR: ${message.replace(/\s+/g, " ").trim()}\n`);
}
