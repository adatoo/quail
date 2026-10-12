## What

<!-- One or two sentences: what does this PR do? -->

## Why

<!-- Link the implementation plan item or issue this addresses. -->

## How to verify

<!-- Commands run, smoke test steps, screenshots for UI changes. -->

## Checklist

- [ ] Builds with zero warnings (`xcodebuild -scheme Quail -configuration Debug build`)
- [ ] Unit tests pass (`xcodebuild -scheme Quail test`) and new logic in
      `Models/`, `DeviceFit/`, `Server/` has tests using a fake `Runtime`
- [ ] No absolute build-machine paths end up in the bundle
- [ ] `docs/IMPLEMENTATION_PLAN.md` checkbox/status updated if this completes
      a listed item
- [ ] The ADR in `docs/adr/` is brought up to date (or a new one added and
      indexed) if this changes or makes a recorded decision
- [ ] Conventional Commits title, and the version bumped for it
      (`PR_TITLE="<PR title>" task version:bump`)
