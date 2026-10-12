# ADR-0046: Automation acts as a GitHub App, not a personal access token

**Date:** 2026-09-25 · **Status:** Accepted

**Decision:** The Auto-merge and Dependabot-bump workflows authenticate as a GitHub App, `quail-release` (Contents and Pull requests: read and write, installed on this repo only), minting a one-hour installation token per run with `actions/create-github-app-token` from the secrets `RELEASE_APP_CLIENT_ID` and `RELEASE_APP_PRIVATE_KEY` (Actions and Dependabot stores). This replaces ADR-0024's `BOT_TOKEN` fine-grained PAT, which was never added: auto-merge never switched on, and every PR since needed a hand merge.
**Why an App:** actions taken with `GITHUB_TOKEN` start no workflows, so a merge or a bump push made with it would neither release nor re-run the checks. A PAT works but belongs to a person, expires, and is broad; an App's token is short-lived, scoped to one repo and attributed to the App. OIDC isn't an option: GitHub's OIDC tokens are for cloud providers, not for its own API.
**Without the secrets** both workflows say so in a notice and skip, as they did without `BOT_TOKEN`; a PR is then merged by hand.
**Revisit if:** a merge queue replaces auto-merge, or the App's key needs rotating (regenerate it, replace the secret in both stores).
