import CryptoKit
import Foundation

/// The one page `quail-server` serves at `/`: pick a model, load or unload it, chat with it. It
/// speaks the same HTTP API as every other client, so it works for GGUF and MLX models alike
/// (ADR D-042). No framework, no build step, no request to any other host.
///
/// It shows text a model wrote, so it is built not to be talked into running any of it: model
/// output only ever goes in as `textContent`, and the Content-Security-Policy allows exactly this
/// script and this style (by hash), no other origin, no framing. `WebUITests` fails the build if
/// the source gains an HTML-injecting API or a URL.
enum WebUI {
    static let response: HTTPResponse = .init(
        status: 200,
        headers: [
            ("Content-Type", "text/html; charset=utf-8"),
            ("Content-Security-Policy", contentSecurityPolicy),
            ("X-Content-Type-Options", "nosniff"),
            ("X-Frame-Options", "DENY"),
            ("Referrer-Policy", "no-referrer"),
            ("Cache-Control", "no-store"),
        ],
        body: .data(Data(html.utf8))
    )

    /// The script and style are allowed by the hash of their exact text, computed here from the
    /// same strings that are embedded, so an edit can't leave the policy stale.
    static let contentSecurityPolicy: String = [
        "default-src 'none'",
        "script-src 'sha256-\(hash(script))'",
        "style-src 'sha256-\(hash(style))'",
        "connect-src 'self'",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'",
    ].joined(separator: "; ")

    static func hash(_ text: String) -> String {
        Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
    }

    static let html = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <title>Quail</title>
    <style>\(style)</style>
    </head>
    <body>
    <header>
      <h1>Quail</h1>
      <span id="build"></span>
      <label>API key <input id="key" type="password" autocomplete="off" spellcheck="false"></label>
    </header>
    <div class="bar">
      <select id="model" aria-label="Model"></select>
      <button id="load" type="button">Load</button>
      <button id="unload" type="button">Unload</button>
      <button id="refresh" type="button" title="Refresh the model list">Refresh</button>
    </div>
    <details class="system">
      <summary>System prompt</summary>
      <textarea id="system" rows="3" placeholder="Optional"></textarea>
    </details>
    <div id="log" aria-live="polite"></div>
    <p id="status" role="status"></p>
    <form id="form">
      <textarea id="input" rows="3" placeholder="Message (Enter to send, Shift+Enter for a new line)"></textarea>
      <div class="actions">
        <button id="send" type="submit">Send</button>
        <button id="stop" type="button" hidden>Stop</button>
        <button id="clear" type="button">Clear</button>
        <span id="timings"></span>
      </div>
    </form>
    <script>\(script)</script>
    </body>
    </html>

    """

    static let style = """

    :root { color-scheme: light dark; --bg: #fbfaf7; --fg: #1d1c1a; --muted: #6d6a63; --line: #dcd8ce; --panel: #f1eee6; --user: #e4ecf7; --accent: #2f6f4f; --error: #b3261e; }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #171614; --fg: #ebe8e1; --muted: #9b978d; --line: #35322d; --panel: #211f1c; --user: #22303f; --accent: #6cc39a; --error: #f2857d; }
    }
    * { box-sizing: border-box; }
    [hidden] { display: none !important; }
    body { margin: 0 auto; max-width: 52rem; height: 100vh; height: 100dvh; padding: 0.75rem 1rem; display: flex; flex-direction: column; gap: 0.6rem; background: var(--bg); color: var(--fg); font: 15px/1.5 system-ui, -apple-system, sans-serif; }
    header { display: flex; align-items: baseline; gap: 0.75rem; flex-wrap: wrap; }
    h1 { margin: 0; font-size: 1.2rem; }
    #build { color: var(--muted); font-size: 0.85rem; flex: 1; }
    label { color: var(--muted); font-size: 0.85rem; }
    input, select, textarea, button { font: inherit; color: inherit; background: var(--panel); border: 1px solid var(--line); border-radius: 6px; padding: 0.35rem 0.6rem; }
    button { cursor: pointer; }
    button:hover:not(:disabled) { border-color: var(--accent); }
    button:disabled { opacity: 0.5; cursor: default; }
    button[type=submit] { background: var(--accent); border-color: var(--accent); color: var(--bg); font-weight: 600; }
    .bar { display: flex; gap: 0.4rem; flex-wrap: wrap; }
    .bar select { flex: 1; min-width: 12rem; }
    .system textarea { width: 100%; margin-top: 0.4rem; }
    summary { color: var(--muted); cursor: pointer; font-size: 0.85rem; }
    #log { flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 0.6rem; padding: 0.25rem 0; }
    .msg { border: 1px solid var(--line); border-radius: 8px; padding: 0.5rem 0.75rem; max-width: 92%; }
    .msg.user { align-self: flex-end; background: var(--user); }
    .msg.assistant { align-self: flex-start; background: var(--panel); }
    .msg pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font: inherit; }
    .msg details { margin-bottom: 0.4rem; }
    .msg details pre { color: var(--muted); font-size: 0.9rem; }
    .msg .call { font: 0.85rem ui-monospace, Menlo, monospace; color: var(--muted); }
    #status { margin: 0; min-height: 1.4em; color: var(--muted); font-size: 0.9rem; }
    #status.error { color: var(--error); }
    #form textarea { width: 100%; resize: vertical; }
    .actions { display: flex; gap: 0.4rem; align-items: center; margin-top: 0.4rem; }
    #timings { color: var(--muted); font-size: 0.85rem; margin-left: auto; }

    """

    static let script = #"""

    "use strict";
    const $ = (id) => document.getElementById(id);
    const els = {};
    for (const id of ["build", "key", "model", "load", "unload", "refresh", "system", "log", "status",
                      "form", "input", "send", "stop", "clear", "timings"]) {
      els[id] = $(id);
    }
    const store = {
      get(name) { try { return localStorage.getItem(name) || ""; } catch (e) { return ""; } },
      set(name, value) { try { localStorage.setItem(name, value); } catch (e) { /* private window */ } },
    };
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    let history = [];
    let controller = null;

    function setStatus(text, isError) {
      els.status.textContent = text || "";
      els.status.className = isError ? "error" : "";
    }

    async function api(path, options) {
      const init = Object.assign({ credentials: "omit", cache: "no-store" }, options);
      init.headers = {};
      const key = els.key.value.trim();
      if (key) { init.headers["Authorization"] = "Bearer " + key; }
      if (init.body) { init.headers["Content-Type"] = "application/json"; }
      const res = await fetch(path, init);
      if (!res.ok) {
        let message = res.status + " " + res.statusText;
        try {
          const body = await res.json();
          if (body.error && body.error.message) { message = body.error.message; }
        } catch (e) { /* not JSON */ }
        const error = new Error(message);
        error.status = res.status;
        throw error;
      }
      return res;
    }

    function fail(error) {
      if (error.status === 401) {
        setStatus("This server needs an API key. Paste it above (Quail: Settings, Endpoint, Copy).", true);
        els.key.focus();
      } else {
        setStatus(error.message, true);
      }
    }

    async function refreshModels() {
      try {
        const res = await api("/v1/models");
        const models = (await res.json()).data || [];
        const wanted = els.model.value || store.get("quail.model");
        els.model.replaceChildren();
        for (const model of models) {
          const option = document.createElement("option");
          option.value = model.id;
          option.textContent = model.id + " (" + (model.status && model.status.value || "?") + ")";
          els.model.append(option);
        }
        if (models.some((model) => model.id === wanted)) { els.model.value = wanted; }
        if (!models.length) { setStatus("No models yet. Add one in Quail.", false); }
        else if (els.status.className !== "error") { setStatus("", false); }
        return models;
      } catch (error) {
        fail(error);
        return [];
      }
    }

    async function showBuild() {
      try {
        const res = await api("/props");
        els.build.textContent = (await res.json()).build_info || "";
      } catch (error) { els.build.textContent = ""; }
    }

    async function manage(action) {
      const model = els.model.value;
      if (!model) { return; }
      setStatus((action === "load" ? "Loading " : "Unloading ") + model + "…", false);
      try {
        await api("/models/" + action, { method: "POST", body: JSON.stringify({ model }) });
        for (let tries = 0; tries < 600; tries++) {
          const models = await refreshModels();
          const entry = models.find((m) => m.id === model);
          if (!entry || !entry.status || entry.status.value !== "loading") { break; }
          await sleep(1000);
        }
        setStatus("", false);
      } catch (error) { fail(error); }
    }

    function bubble(role, text) {
      const root = document.createElement("div");
      root.className = "msg " + role;
      const thinking = document.createElement("details");
      thinking.hidden = true;
      const summary = document.createElement("summary");
      summary.textContent = "Thinking";
      const thinkingText = document.createElement("pre");
      thinking.append(summary, thinkingText);
      const body = document.createElement("pre");
      body.textContent = text;
      root.append(thinking, body);
      els.log.append(root);
      els.log.scrollTop = els.log.scrollHeight;
      return { root, thinking, thinkingText, body };
    }

    function setBusy(busy) {
      els.send.hidden = busy;
      els.stop.hidden = !busy;
      els.model.disabled = busy;
    }

    function handleChunk(data, reply, ui) {
      if (data === "[DONE]") { return; }
      const chunk = JSON.parse(data);
      if (chunk.error) { throw new Error(chunk.error.message || "the server reported an error"); }
      if (chunk.timings) { reply.timings = chunk.timings; }
      const delta = chunk.choices && chunk.choices[0] && chunk.choices[0].delta;
      if (!delta) { return; }
      if (delta.reasoning_content) {
        ui.thinking.hidden = false;
        ui.thinkingText.textContent += delta.reasoning_content;
      }
      if (delta.content) {
        reply.content += delta.content;
        ui.body.textContent = reply.content;
      }
      for (const call of delta.tool_calls || []) {
        const line = document.createElement("pre");
        line.className = "call";
        line.textContent = JSON.stringify(call.function);
        ui.root.append(line);
      }
      els.log.scrollTop = els.log.scrollHeight;
    }

    async function readStream(res, reply, ui) {
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      for (;;) {
        const { done, value } = await reader.read();
        if (done) { break; }
        buffer += decoder.decode(value, { stream: true });
        let end;
        while ((end = buffer.indexOf("\n\n")) >= 0) {
          const frame = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          for (const line of frame.split("\n")) {
            if (line.startsWith("data: ")) { handleChunk(line.slice(6), reply, ui); }
          }
        }
      }
    }

    function showTimings(t) {
      if (!t) { els.timings.textContent = ""; return; }
      const speed = t.predicted_per_second ? t.predicted_per_second.toFixed(1) + " tok/s · " : "";
      els.timings.textContent = speed + t.predicted_n + " tokens · prompt " + (t.prompt_n + (t.cache_n || 0));
    }

    async function send() {
      const text = els.input.value.trim();
      const model = els.model.value;
      if (!text || controller) { return; }
      if (!model) { setStatus("Choose a model first.", true); return; }
      store.set("quail.model", model);
      els.input.value = "";
      setStatus("", false);
      els.timings.textContent = "";
      history.push({ role: "user", content: text });
      bubble("user", text);
      const ui = bubble("assistant", "");
      const messages = [];
      const system = els.system.value.trim();
      if (system) { messages.push({ role: "system", content: system }); }
      messages.push(...history);
      const reply = { content: "", timings: null };
      controller = new AbortController();
      setBusy(true);
      try {
        const res = await api("/v1/chat/completions", {
          method: "POST", signal: controller.signal, body: JSON.stringify({ model, messages, stream: true }),
        });
        await readStream(res, reply, ui);
      } catch (error) {
        if (error.name !== "AbortError") { fail(error); }
      } finally {
        controller = null;
        setBusy(false);
        if (reply.content) { history.push({ role: "assistant", content: reply.content }); }
        else { history.pop(); if (!ui.thinkingText.textContent) { ui.root.remove(); } }
        showTimings(reply.timings);
        refreshModels();
      }
    }

    els.form.addEventListener("submit", (event) => { event.preventDefault(); send(); });
    els.input.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing) { event.preventDefault(); send(); }
    });
    els.stop.addEventListener("click", () => { if (controller) { controller.abort(); } });
    els.clear.addEventListener("click", () => {
      if (controller) { controller.abort(); }
      history = [];
      els.log.replaceChildren();
      els.timings.textContent = "";
      setStatus("", false);
    });
    els.load.addEventListener("click", () => manage("load"));
    els.unload.addEventListener("click", () => manage("unload"));
    els.refresh.addEventListener("click", () => { refreshModels(); showBuild(); });
    els.model.addEventListener("change", () => store.set("quail.model", els.model.value));
    els.key.addEventListener("change", () => { store.set("quail.key", els.key.value.trim()); refreshModels(); showBuild(); });

    els.key.value = store.get("quail.key");
    refreshModels();
    showBuild();

    """#
}
