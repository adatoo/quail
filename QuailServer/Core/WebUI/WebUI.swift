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
        <button id="new-chat" type="button" title="New chat (Ctrl+K)">New chat</button>
        <input id="search" type="search" placeholder="Search chats" aria-label="Search chats" autocomplete="off">
      </div>
      <nav id="conversations"></nav>
      <div class="side-bottom">
        <button id="export" type="button" title="Save every chat as a JSON file">Export</button>
        <button id="import" type="button" title="Add chats from an exported JSON file">Import</button>
        <input id="import-file" type="file" accept="application/json,.json" hidden>
      </div>
    </aside>
    <main>
      <header>
        <button id="toggle-sidebar" type="button" aria-label="Show or hide chats" title="Chats">Chats</button>
        <h1>Quail</h1>
        <span id="build"></span>
        <label>API key <input id="key" type="password" autocomplete="off" spellcheck="false"></label>
      </header>
      <div class="bar">
        <select id="model" aria-label="Model"></select>
        <button id="load" type="button">Load</button>
        <button id="unload" type="button">Unload</button>
        <button id="refresh" type="button" title="Refresh the model list">Refresh</button>
        <button id="open-settings" type="button" title="Generation settings">Settings</button>
      </div>
      <details class="system">
        <summary>System prompt</summary>
        <textarea id="system" rows="3" placeholder="Optional, kept with this chat"></textarea>
      </details>
      <div id="log" aria-live="polite"></div>
      <p id="status" role="status"></p>
      <form id="form">
        <div id="attachments" hidden></div>
        <textarea id="input" rows="3" placeholder="Message (Enter to send, Shift+Enter for a new line; paste or drop images and text files)"></textarea>
        <div class="actions">
          <button id="send" type="submit">Send</button>
          <button id="attach" type="button" title="Attach images (vision models) or text files">Attach</button>
          <input id="attach-file" type="file" multiple hidden>
          <button id="stop" type="button" hidden title="Stop (Esc)">Stop</button>
          <span id="timings"></span>
        </div>
      </form>
    </main>
    <dialog id="settings" aria-labelledby="settings-title">
      <h2 id="settings-title">Generation settings</h2>
      <p class="hint">Blank uses the server's default. Kept in this browser, for every chat.</p>
      <div id="settings-fields"></div>
      <div class="actions">
        <button id="settings-reset" type="button">Reset to defaults</button>
        <button id="settings-close" type="button">Done</button>
      </div>
    </dialog>
    <script>\(script)</script>
    </body>
    </html>

    """
}
