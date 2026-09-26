import CryptoKit
import Foundation

/// The one page `quail-server` serves at `/`: conversations kept in the browser, a model picker with load
/// and unload, generation settings, Markdown replies and per-message edit, regenerate, copy and delete. It
/// speaks the same HTTP API as every other client, so it works for GGUF and MLX models alike (ADR D-042).
/// No framework, no build step, no request to any other host.
///
/// It shows text a model wrote, so it is built not to be talked into running any of it: Markdown is parsed
/// by our own small parser into DOM nodes (`WebUIMarkdown`), never into HTML; links are kept only for
/// http(s) and mailto; and the Content-Security-Policy allows exactly this script and this style (by hash),
/// no other origin, no framing. `WebUITests` fails the build if the source gains an HTML-injecting API or a
/// URL. The page is split over `WebUIPage` (this), `WebUIStyle`, `WebUIMarkdown` and `WebUIScript`.
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

    /// The one inline script: the Markdown parser, then the page's own code.
    static let script = markdown + app

    /// The script and style are allowed by the hash of their exact text, computed here from the
    /// same strings that are embedded, so an edit can't leave the policy stale.
    static let contentSecurityPolicy: String = [
        "default-src 'none'",
        "script-src 'sha256-\(hash(script))'",
        "style-src 'sha256-\(hash(style))'",
        "connect-src 'self'",
        // Thumbnails of the images a user attaches, which are data: URLs; nothing is fetched.
        "img-src data:",
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
    <aside id="sidebar" aria-label="Chats">
      <div class="side-top">
        <button id="new-chat" type="button" class="primary" title="New chat (Ctrl+K)">New chat</button>
        <input id="search" type="search" placeholder="Search chats" aria-label="Search chats" autocomplete="off">
      </div>
      <nav id="conversations"></nav>
      <div class="side-bottom">
        <div class="side-links">
          <button id="export" type="button" class="link" title="Save every chat as a JSON file">Export</button>
          <button id="import" type="button" class="link" title="Add chats from an exported JSON file">Import</button>
          <input id="import-file" type="file" accept="application/json,.json" hidden>
        </div>
        <div id="build"></div>
      </div>
    </aside>
    <main>
      <header class="topbar">
        <button id="toggle-sidebar" type="button" class="icon" aria-label="Show or hide chats" title="Chats"><svg viewBox="0 0 20 20" aria-hidden="true"><rect x="2.5" y="3.5" width="15" height="13" rx="2" fill="none" stroke="currentColor" stroke-width="1.5"/><line x1="7.5" y1="3.5" x2="7.5" y2="16.5" stroke="currentColor" stroke-width="1.5"/></svg></button>
        <div class="model-picker">
          <span id="model-dot" class="dot" aria-hidden="true"></span>
          <select id="model" aria-label="Model"></select>
        </div>
        <button id="model-action" type="button" class="small">Load</button>
        <span class="spacer"></span>
        <button id="system-toggle" type="button" class="small ghost" aria-expanded="false" title="The system prompt for this chat">System prompt</button>
        <button id="key-toggle" type="button" class="small ghost" aria-expanded="false" title="The server's API key">Key</button>
        <button id="refresh" type="button" class="icon" aria-label="Refresh the model list" title="Refresh"><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M15.5 10a5.5 5.5 0 1 1-1.6-3.9" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><path d="M14.5 2.8v3.6h-3.6" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
        <button id="open-settings" type="button" class="icon" aria-label="Generation settings" title="Settings"><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 6h9M15 6h2M3 14h2M8 14h9" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><circle cx="13.5" cy="6" r="1.8" fill="none" stroke="currentColor" stroke-width="1.6"/><circle cx="6.5" cy="14" r="1.8" fill="none" stroke="currentColor" stroke-width="1.6"/></svg></button>
      </header>
      <div id="key-panel" class="panel" hidden>
        <label for="key">API key</label>
        <input id="key" type="password" autocomplete="off" spellcheck="false" placeholder="Paste the key from Quail: Settings, Endpoint, Copy">
        <p class="hint">Opening the chat from Quail's menu fills this in for you. It stays in this browser only.</p>
      </div>
      <div id="system-panel" class="panel" hidden>
        <label for="system">System prompt</label>
        <textarea id="system" rows="3" placeholder="Instructions for this chat, for example: You are a concise assistant who answers in British English."></textarea>
        <p class="hint">Kept with this chat. The model reads it before every message.</p>
      </div>
      <div id="log" aria-live="polite"></div>
      <p id="status" role="status"></p>
      <form id="form" class="composer">
        <div id="attachments" hidden></div>
        <textarea id="input" rows="1" placeholder="Message the model…" aria-label="Message"></textarea>
        <div class="composer-bar">
          <button id="attach" type="button" class="icon" aria-label="Attach images or text files" title="Attach images (vision models) or text files"><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M13.5 6.5 8 12a1.8 1.8 0 0 0 2.5 2.5l6-6a3.5 3.5 0 0 0-5-5l-6.2 6.2a5.2 5.2 0 0 0 7.4 7.4L17 12.8" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
          <input id="attach-file" type="file" multiple hidden>
          <span class="hint">Enter to send · Shift+Enter for a new line</span>
          <span id="timings"></span>
          <button id="stop" type="button" class="stop" hidden title="Stop (Esc)">Stop</button>
          <button id="send" type="submit" class="send" title="Send (Enter)">Send</button>
        </div>
      </form>
    </main>
    <dialog id="settings" aria-labelledby="settings-title">
      <div class="dialog-head">
        <h2 id="settings-title">Generation settings</h2>
        <button id="settings-x" type="button" class="icon" aria-label="Close"><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M5 5l10 10M15 5 5 15" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg></button>
      </div>
      <p class="hint">Blank uses the server's default. Kept in this browser, for every chat. Select ⓘ for what a setting does.</p>
      <div id="settings-fields"></div>
      <div class="actions">
        <button id="settings-reset" type="button">Reset to defaults</button>
        <button id="settings-close" type="button" class="primary">Done</button>
      </div>
    </dialog>
    <script>\(script)</script>
    </body>
    </html>

    """
}
