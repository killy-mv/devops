const test = require("node:test");
const assert = require("node:assert");
const http = require("node:http");
const { renderPage, handler } = require("./app");

test("page shows the bakery name", () => {
  assert.match(renderPage(), /<h1>Sweet Bakery<\/h1>/);
});

test("page shows opening hours", () => {
  assert.match(renderPage(), /Open \d+(am|pm) - \d+(am|pm)/);
});

test("server answers / and /health", async () => {
  const server = http.createServer(handler).listen(0); // 0 = any free port
  const base = `http://localhost:${server.address().port}`;
  try {
    const home = await fetch(base);
    assert.strictEqual(home.status, 200);

    const health = await fetch(`${base}/health`);
    assert.strictEqual((await health.json()).status, "ok");
  } finally {
    server.close();
  }
});
