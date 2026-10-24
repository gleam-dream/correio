// Real Chromium navigation and cookies against local peers.
import assert from "node:assert/strict";
import { chromium } from "playwright-core";
import http from "node:http";
import readline from "node:readline";

const origin = process.argv[2];
assert.match(origin, /^http:\/\/127\.0\.0\.1:\d+$/);
let browser;
let webmail;
const stdin = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});
const incoming = [];
const waiting = [];
stdin.on("line", (line) =>
  waiting.length ? waiting.shift()(line) : incoming.push(line),
);
const readLine = () =>
  incoming.length
    ? Promise.resolve(incoming.shift())
    : new Promise((resolve) => waiting.push(resolve));
try {
  browser = await chromium.launch({
    executablePath: process.env.CORREIO_BROWSER_CHROMIUM || "chromium",
    headless: true,
  });
  const context = await browser.newContext({
    viewport: { width: 1100, height: 1800 },
  });
  const requests = [];
  // Register before any navigation, including sandboxed out-of-process frames.
  context.on("request", (request) => requests.push(request.url()));
  const page = await context.newPage();
  const evaluate = (expression) => page.evaluate(expression);
  const until = async (expression, label) => {
    try {
      await page.waitForFunction(expression, undefined, { timeout: 10000 });
    } catch {
      throw new Error(`Browser condition failed: ${label}`);
    }
  };
  await page.goto(origin);
  await until(
    "document.readyState === 'complete' && !!document.querySelector('form')",
    "issue form ready",
  );
  await evaluate(
    "document.querySelector('input[name=email]').value='alice@example.com'; document.querySelector('form').requestSubmit(); true",
  );
  await until(
    "document.body.innerText.includes('If this account exists')",
    "neutral issue response",
  );
  let cookies = await context.cookies(origin);
  const binding = cookies.find((cookie) => cookie.name === "browser");
  assert.equal(binding.sameSite, "Lax");
  assert.equal(binding.httpOnly, true);
  await context.addCookies([
    {
      name: "session",
      value: "attacker-fixed-session",
      url: origin,
      httpOnly: true,
      sameSite: "Strict",
    },
  ]);
  console.log("ISSUED");
  const link = await readLine();
  assert.equal(new URL(link).origin, origin);
  const beforeInspection = requests.length;
  await page.goto(`${origin}/dev/mailbox`);
  await until(
    "!!document.querySelector('[data-message-id]')",
    "development mailbox inbox",
  );
  assert.equal(
    await evaluate("document.querySelectorAll('[data-message-id]').length"),
    2,
  );
  await evaluate("document.querySelector('[data-message-id] a').click(); true");
  await until(
    "!!document.querySelector('iframe') && document.readyState === 'complete'",
    "mailbox detail preview",
  );
  assert.equal(await evaluate("window.mailboxPwned === undefined"), true);
  assert.equal(
    await evaluate("document.querySelector('iframe').getAttribute('sandbox')"),
    "",
  );
  assert.equal(
    await evaluate(
      "document.querySelector('#html-source').innerText.includes('http-equiv=refresh')",
    ),
    true,
  );
  const preview = page.frameLocator("iframe");
  await preview.locator("h2").waitFor({ state: "visible", timeout: 10000 });
  assert.equal(await preview.locator("h2").innerText(), "Sign in safely");
  assert.equal(
    await preview
      .locator(
        "script,form,img,iframe,a,[src],[href],[onfocus],meta[http-equiv=refresh]",
      )
      .count(),
    0,
  );
  const child = page.frames().find((frame) => frame.parentFrame());
  assert.equal(
    await child.evaluate(() => location.href),
    "about:srcdoc",
    "Preview unexpectedly navigated",
  );
  // Observe the fully loaded frame long enough for zero-delay refresh or script
  // regressions; the browser context observes requests from every frame.
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.equal(
    requests
      .slice(beforeInspection)
      .some((url) => url.includes("/login") || url.includes("/mailbox-trap")),
    false,
  );
  assert.equal(await evaluate("window.mailboxPwned === undefined"), true);
  await page.screenshot({ path: "/tmp/correio-mailbox.png", fullPage: true });

  webmail = http.createServer((_request, response) => {
    response.setHeader("Content-Type", "text/html");
    response.end(
      `<a id="login" href="${link.replaceAll("&", "&amp;")}">Open email sign-in link</a>`,
    );
  });
  await new Promise((resolve) => webmail.listen(0, "127.0.0.1", resolve));
  const mailOrigin = `http://localhost:${webmail.address().port}`;
  await page.goto(mailOrigin);
  await until(
    "location.hostname === 'localhost' && !!document.querySelector('#login')",
    "cross-site webmail",
  );
  await evaluate("document.querySelector('#login').click(); true");
  await until(
    "location.hostname === '127.0.0.1' && location.pathname === '/confirm' && !!document.querySelector('form')",
    "Lax cookie on email navigation",
  );
  assert.equal(await evaluate("location.search"), "");
  await page.goto(`${origin}/session`);
  await until(
    "document.body.innerText === 'No session'",
    "preview has no session",
  );
  await page.goto(`${origin}/confirm`);
  await until(
    "!!document.querySelector('input[name=csrf]')",
    "confirmation form restored",
  );
  console.log("PREVIEW");
  assert.equal(await readLine(), "CONTINUE");
  // Actual browser form submission supplies Origin and the rendered CSRF input.
  await evaluate("document.querySelector('form').requestSubmit(); true");
  await until(
    "document.body.innerText === 'Signed in'",
    "intentional confirmation POST",
  );
  await page.goto(`${origin}/session`);
  await until(
    "document.body.innerText === 'Authenticated native account'",
    "session cookie authenticates",
  );
  cookies = await context.cookies(origin);
  const session = cookies.find((cookie) => cookie.name === "session");
  assert.equal(session.httpOnly, true);
  assert.equal(session.sameSite, "Strict");
  assert.notEqual(session.value, "attacker-fixed-session");
  console.log(
    JSON.stringify({
      browser: "Chromium",
      development_mailbox: true,
      hostile_preview_inert: true,
      cross_site_webmail: true,
      initiating_cookie: "Lax",
      session_cookie: "Strict",
      get_unconsumed: true,
      confirmation_post: true,
      session_rotated: true,
    }),
  );
} catch (error) {
  // Browser errors can contain sign-in URLs or cookies. Report only source location.
  const source = error.stack?.match(/browser-e2e\.mjs:(\d+):(\d+)/);
  console.error(
    `Browser integration test failed${source ? ` at ${source[1]}:${source[2]}` : ""}`,
  );
  process.exitCode = 1;
} finally {
  stdin.close();
  process.stdin.destroy();
  if (webmail) {
    webmail.closeAllConnections();
    await new Promise((resolve) => webmail.close(resolve));
  }
  await browser?.close();
}
