# ADR-0062: A website: hand-written HTML in `website/`, on GitHub Pages

**Date:** 2026-09-28 · **Status:** Accepted

**Situation:** Quail had no home page, only a README. The owner wants the app to link to one before 1.0, with docs the app's long captions can point at instead of explaining everything in place. They bought `quail-ai.app` and `quail-ai.com`, both on Cloudflare DNS.

**Decision:** A landing page and ten short docs pages in `website/`, as plain HTML with one stylesheet: no build step, no framework, no JavaScript except on the 404 page.
- **Pages:** getting started, models, connect a tool, network and API key, power, benchmark, the `quail` command, troubleshooting and privacy, plus an index.
- **The docs sidebar** is repeated on each page. `scripts/check-site` (`task site:check`, run by the workflow) fails if the copies differ, and also checks titles, descriptions and every link and image inside the site, including `#fragments`.
- **Links are relative,** so the site works both at `https://adatoo.github.io/quail/` and at the root of a domain.
- **Deploy:** `.github/workflows/pages.yml` checks the site on pull requests and deploys it from `main` with `actions/deploy-pages`. Pages must be switched to "GitHub Actions" in the repository's settings once; the workflow doesn't turn it on itself.
- **Domain: `https://quail-ai.app`**, with `quail-ai.com` redirecting to it.
  - **Why `.app` is the address:** it names what Quail is (the Homebrew cask is `quail-ai` too), and every `.app` domain is HTTPS-only in browsers. Anyone who types `.com` still lands on the site.
  - **The custom domain is a repository Pages setting** (Settings → Pages, or `gh api -X PUT repos/adatoo/quail/pages -f cname=quail-ai.app`). It isn't a `website/CNAME` file: GitHub ignores that file when an Actions workflow deploys.
  - **`quail-ai.app`'s records point straight at GitHub Pages and aren't proxied** (DNS only). GitHub issues and renews its certificate; `www` is a CNAME to `adatoo.github.io`, and GitHub redirects it to the root. The domain is verified on the GitHub account (a `_github-pages-challenge-adatoo` TXT record), so no one else can claim it.
  - **`quail-ai.com` and `www.quail-ai.com` are proxied by Cloudflare.** A Redirect Rule sends each path to the same path on `https://quail-ai.app` (301), with Cloudflare's own certificate.
  - **If `quail-ai.app` is ever proxied** (for analytics or caching), use SSL/TLS "Full (strict)", never "Flexible", which loops with GitHub's enforced HTTPS.
- **Screenshots:** `task site:screenshots` renders the Quail window, light and dark, through the snapshot suite (`UISnapshotTests.websiteScreenshots`).
  - The sidebar and page are drawn side by side, because offscreen rendering leaves a real split view's sidebar blank.
  - Rendered offscreen, the window is inactive, so the sidebar's labels are grey. Real screenshots from a running app can replace these images.

**Alternatives:**
- **A static site generator** (Jekyll, Hugo, Astro Starlight): Markdown docs and a shared layout, but a toolchain to install and pin for about ten pages. The repo keeps dependencies to what the app needs (AGENTS.md), and `quail-server`'s own page is hand-written too (ADR-0042).
- **Docs in the repo's Markdown only:** no landing page, and GitHub's rendering is the look.

**Revisit if:** the docs grow past what one person keeps consistent by hand (about 20 pages), or need search. Then a generator earns its keep.

**Amended 2026-09-30 (the comparison's results, and "How it works"):**
- `compare.html` shows the 2026-09-30 comparison's headline results (`task bench:site`), beside the sourced feature table.
- **A new `how-it-works.html`,** kept brief, covers:
  - what Quail is for;
  - how it's built, as a diagram in HTML;
  - how speed is measured and improved;
  - what the first comparison changed, as a card for each change.
- **The details go on their own pages** under `website/performance/`: the comparison's method, several requests at once on MLX, Qwen3.5 and 3.6 on MLX, MLX memory, and long prompts on GGUF. Each is found → why → changed → result, with its issue and PR, and what's still to do. The owner asked for this layout: a short page, with callouts for readers who want more.
- **Linked from:** every page's header ("How it works", hidden on narrow screens), and the footers of the top-level pages.
