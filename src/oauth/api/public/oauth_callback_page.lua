local http = require("http")

local STATUS = http.STATUS

local PAGE = [[<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Authorization</title>
  <style>
    :root { color-scheme: light dark; }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #0f172a;
      color: #f8fafc;
    }
    main {
      width: min(420px, calc(100vw - 32px));
      text-align: center;
    }
    .mark {
      width: 64px;
      height: 64px;
      margin: 0 auto 20px;
      border-radius: 50%;
      display: grid;
      place-items: center;
      background: #1e293b;
      color: #94a3b8;
      font-size: 30px;
      font-weight: 700;
    }
    h1 {
      margin: 0 0 10px;
      font-size: 24px;
      line-height: 1.2;
    }
    p {
      margin: 0;
      color: #cbd5e1;
      line-height: 1.5;
    }
    .ok .mark { background: #059669; color: #ffffff; }
    .fail .mark { background: #dc2626; color: #ffffff; }
  </style>
</head>
<body>
  <main id="state">
    <div class="mark">...</div>
    <h1>Completing authorization</h1>
    <p>You can close this window when authorization is complete.</p>
  </main>
  <script>
    const stateEl = document.getElementById("state");
    function render(kind, title, message) {
      stateEl.className = kind;
      stateEl.querySelector(".mark").textContent = kind === "ok" ? "OK" : "!";
      stateEl.querySelector("h1").textContent = title;
      stateEl.querySelector("p").textContent = message;
    }
    async function complete() {
      const params = new URLSearchParams(window.location.search);
      const payload = {
        code: params.get("code") || "",
        state: params.get("state") || "",
        error: params.get("error") || "",
        error_description: params.get("error_description") || ""
      };
      try {
        const response = await fetch(window.location.pathname, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload)
        });
        const data = await response.json().catch(() => ({}));
        if (response.ok && data.success) {
          render("ok", "Authorization complete", "This window can now be closed.");
          if (window.opener) window.opener.postMessage({ type: "oauth:success" }, window.location.origin);
          return;
        }
        render("fail", "Authorization failed", data.error || "The provider callback could not be completed.");
      } catch (err) {
        render("fail", "Authorization failed", String(err && err.message || err));
      }
    }
    complete();
  </script>
</body>
</html>]]

local function handler()
    local res = http.response()
    if not res then
        return nil, "Failed to get HTTP context"
    end

    res:set_status(STATUS.OK)
    res:set_content_type("text/html; charset=utf-8")
    res:write(PAGE)
end

return {
    handler = handler
}
