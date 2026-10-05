const http = require("node:http");

const BAKERY_NAME = "Sweet Bakery";
const OPENING_HOURS = "Open 8am - 5pm";
// Set by the pipeline at build time, so you can tell which commit is running
const VERSION = process.env.GIT_SHA || "dev";

function renderPage() {
  return `<h1>${BAKERY_NAME}</h1>
<p>${OPENING_HOURS}</p>
<p><small>Version: ${VERSION.slice(0, 7)}</small></p>
`;
}

function handler(req, res) {
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ status: "ok", version: VERSION }));
  }
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(renderPage());
}

// Start the server only when run directly (`node app.js`), not when imported by tests
if (require.main === module) {
  const port = process.env.PORT || 3000;
  http.createServer(handler).listen(port, () => {
    console.log(`Bakery listening on http://localhost:${port}`);
  });
}

module.exports = { renderPage, handler, BAKERY_NAME };
