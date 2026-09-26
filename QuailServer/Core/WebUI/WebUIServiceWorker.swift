import Foundation

extension WebUI {
    /// What `/sw.js` answers. llama.cpp's own page registers a Workbox service worker at `/sw.js` that keeps
    /// serving its cached copy of `/` for the same origin, so after the app switched from llama-server to
    /// `quail-server` on the same port, the browser still showed llama.cpp's page. The browser checks a
    /// registered worker's script on every navigation, bypassing the worker; finding this one, it installs it,
    /// and this one empties the caches, removes itself and reloads the open pages from the server (ADR D-042).
    static let serviceWorkerKillSwitch = #"""
    "use strict";
    self.addEventListener("install", () => { self.skipWaiting(); });
    self.addEventListener("activate", (event) => {
      event.waitUntil((async () => {
        for (const name of await caches.keys()) { await caches.delete(name); }
        await self.registration.unregister();
        for (const client of await self.clients.matchAll({ type: "window" })) {
          try { await client.navigate(client.url); } catch (e) { /* a page that can't be navigated reloads itself */ }
        }
      })());
    });

    """#

    static let serviceWorkerResponse: HTTPResponse = .init(
        status: 200,
        headers: [
            ("Content-Type", "application/javascript; charset=utf-8"),
            ("Cache-Control", "no-store"),
            ("Service-Worker-Allowed", "/"),
            ("X-Content-Type-Options", "nosniff"),
        ],
        body: .data(Data(serviceWorkerKillSwitch.utf8))
    )
}
