// Real Chromium navigation and cookies; no npm dependencies or external websites.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

const origin = process.argv[2];
assert.match(origin, /^http:\/\/127\.0\.0\.1:\d+$/);
const profile = await mkdtemp(path.join(os.tmpdir(), "correio-browser-"));
const chrome = spawn(
  process.env.CORREIO_BROWSER_CHROMIUM || "chromium",
  [
    "--headless=new",
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--disable-gpu",
    "--no-first-run",
    "--disable-background-networking",
    "--disable-component-update",
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "about:blank",
  ],
  { stdio: ["ignore", "ignore", "pipe"] },
);
let socket;
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
  const endpoint = await new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error("Chromium startup deadline")),
      30000,
    );
    chrome.on("error", reject);
    chrome.on("exit", () =>
      reject(new Error("Chromium exited during startup")),
    );
    let text = "";
    chrome.stderr.on("data", (chunk) => {
      text = (text + chunk).slice(-20000);
      const match = text.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) {
        clearTimeout(timeout);
        resolve(match[1]);
      }
    });
  });
  socket = new WebSocket(endpoint);
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
  });
  let next = 0;
  const pending = new Map();
  const requests = [];
  const frameSessions = new Map();
  const attachmentErrors = [];
  socket.onmessage = ({ data }) => {
    const message = JSON.parse(data);
    if (message.method === "Target.attachedToTarget") {
      const child = message.params;
      frameSessions.set(child.targetInfo.targetId, child.sessionId);
      // The child waits for debugger release, so observation starts before
      // its document can request resources or navigate.
      (async () => {
        await send("Network.enable", {}, child.sessionId);
        await send("Runtime.enable", {}, child.sessionId);
        await send("Runtime.runIfWaitingForDebugger", {}, child.sessionId);
      })().catch((error) => attachmentErrors.push(error.message));
    }

    if (message.method === "Network.requestWillBeSent")
      requests.push(message.params.request.url);
    if (pending.has(message.id)) {
      const { resolve, reject, timeout } = pending.get(message.id);
      pending.delete(message.id);
      clearTimeout(timeout);
      message.error
        ? reject(new Error("Browser protocol command failed"))
        : resolve(message.result);
    }
  };
  const send = (method, params = {}, sessionId) =>
    new Promise((resolve, reject) => {
      const id = ++next;
      const timeout = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`Browser deadline: ${method}`));
      }, 10000);
      pending.set(id, { resolve, reject, timeout });
      socket.send(
        JSON.stringify({
          id,
          method,
          params,
          ...(sessionId ? { sessionId } : {}),
        }),
      );
    });
  const { targetId } = await send("Target.createTarget", {
    url: "about:blank",
  });
  const { sessionId } = await send("Target.attachToTarget", {
    targetId,
    flatten: true,
  });
  const command = (method, params) => send(method, params, sessionId);
  await command("Page.enable");
  await command("Emulation.setDeviceMetricsOverride", {
    width: 1100,
    height: 1800,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await command("Runtime.enable");
  await command("Network.enable");
  await command("Target.setAutoAttach", {
    autoAttach: true,
    waitForDebuggerOnStart: true,
    flatten: true,
  });
  const evaluate = async (expression) => {
    const reply = await command("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
      userGesture: true,
    });
    if (reply.exceptionDetails)
      throw new Error("Browser page evaluation failed");
    return reply.result.value;
  };
  const until = async (expression, label) => {
    for (let attempt = 0; attempt < 200; attempt++) {
      try {
        if (await evaluate(expression)) return;
      } catch {
        /* navigation replaces the execution context */
      }
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    const route = await evaluate("location.pathname");
    const bodyKind = await evaluate(
      "['Request refused', 'Bad request', 'Internal error', 'Email sign-in link'].find(value => document.body.innerText.includes(value)) || 'other page'",
    );
    throw new Error(
      `Browser condition failed: ${label}; route=${route}; page=${bodyKind}`,
    );
  };
  await command("Page.navigate", { url: origin });
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
  let cookies = (await command("Network.getCookies", { urls: [origin] }))
    .cookies;
  const binding = cookies.find((cookie) => cookie.name === "browser");
  assert.equal(binding.sameSite, "Lax");
  assert.equal(binding.httpOnly, true);
  await command("Network.setCookie", {
    name: "session",
    value: "attacker-fixed-session",
    url: origin,
    httpOnly: true,
    sameSite: "Strict",
  });
  console.log("ISSUED");
  const link = await readLine();
  assert.equal(new URL(link).origin, origin);
  const beforeInspection = requests.length;
  await command("Page.navigate", { url: `${origin}/dev/mailbox` });
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
  const previewDeadline = Date.now() + 10000;
  let previewReady = false;
  while (Date.now() < previewDeadline && !previewReady) {
    assert.deepEqual(attachmentErrors, []);
    const targets = await send("Target.getTargets");
    const preview = targets.targetInfos.find(
      (target) => target.type === "iframe" && target.parentId === targetId,
    );
    const previewSession = preview && frameSessions.get(preview.targetId);
    if (previewSession) {
      assert.ok(
        preview.url === "about:srcdoc",
        "Preview unexpectedly navigated",
      );
      const content = await send(
        "Runtime.evaluate",
        {
          expression:
            "({ready: document.readyState, heading: document.querySelector('h2')?.innerText, active: document.querySelectorAll('script,form,img,iframe,a,[src],[href],[onfocus],meta[http-equiv=refresh]').length})",
          returnByValue: true,
        },
        previewSession,
      );
      const value = content.result.value;
      previewReady =
        value?.ready === "complete" && value?.heading === "Sign in safely";
      if (previewReady) assert.equal(value.active, 0);
    }
    if (!previewReady) await new Promise((resolve) => setTimeout(resolve, 25));
  }
  assert.ok(
    previewReady,
    "Sandboxed formatting preview loaded before deadline",
  );
  // Observe the fully loaded frame long enough for zero-delay refresh or script
  // regressions; both parent and child sessions have network observation.
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.equal(
    requests
      .slice(beforeInspection)
      .some((url) => url.includes("/login") || url.includes("/mailbox-trap")),
    false,
  );
  assert.equal(await evaluate("window.mailboxPwned === undefined"), true);
  const screenshot = await command("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: true,
  });
  await writeFile(
    "/tmp/correio-mailbox.png",
    Buffer.from(screenshot.data, "base64"),
  );

  webmail = http.createServer((_request, response) => {
    response.setHeader("Content-Type", "text/html");
    response.end(
      `<a id="login" href="${link.replaceAll("&", "&amp;")}">Open email sign-in link</a>`,
    );
  });
  await new Promise((resolve) => webmail.listen(0, "127.0.0.1", resolve));
  const mailOrigin = `http://localhost:${webmail.address().port}`;
  await command("Page.navigate", { url: mailOrigin });
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
  await command("Page.navigate", { url: `${origin}/session` });
  await until(
    "document.body.innerText === 'No session'",
    "preview has no session",
  );
  await command("Page.navigate", { url: `${origin}/confirm` });
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
  await command("Page.navigate", { url: `${origin}/session` });
  await until(
    "document.body.innerText === 'Authenticated native account'",
    "session cookie authenticates",
  );
  cookies = (await command("Network.getCookies", { urls: [origin] })).cookies;
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
  // Never print page URLs, captured links, cookies, or raw browser messages.
  console.error(error instanceof Error ? error.message : "Browser test failed");
  process.exitCode = 1;
} finally {
  stdin.close();
  process.stdin.destroy();
  if (socket) socket.close();
  if (webmail) {
    webmail.closeAllConnections();
    await new Promise((resolve) => webmail.close(resolve));
  }
  chrome.kill("SIGTERM");
  await new Promise((resolve) => {
    if (chrome.exitCode !== null) resolve();
    else {
      chrome.once("exit", resolve);
      setTimeout(() => {
        chrome.kill("SIGKILL");
        resolve();
      }, 3000).unref();
    }
  });
  await rm(profile, {
    recursive: true,
    force: true,
    maxRetries: 3,
    retryDelay: 100,
  });
}
