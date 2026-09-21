# Contributing to Quail

Quail is pre-alpha and developed in the open on a private repo until MVP; the
process below is what we'll use once it's public too.

## Before you start

Read [AGENTS.md](AGENTS.md) for conventions, build commands and the
definition of done, then [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) for the design and
what's next. [docs/DECISIONS.md](docs/DECISIONS.md) explains why things are
the way they are — add a new `D-nnn` entry whenever you change a decision
recorded there.

## Workflow

1. Branch from `main`: `feat/…`, `fix/…`, or `chore/…`.
2. Keep commits scoped and use [Conventional Commits](https://www.conventionalcommits.org/)-style
   messages (`feat:`, `fix:`, `docs:`, `chore:`, `test:`).
3. Open a PR against `main`. CI (`build-and-test`) must pass before merge.
4. `main` is protected: no force-push, no direct deletion, status checks
   required.
5. Squash-merge PRs so `main` has one commit per unit of work.

## Definition of done

See the "Definition of done for a task" section in [AGENTS.md](AGENTS.md):
zero warnings on both schemes, unit tests for new logic in `Models/`,
`DeviceFit/` and `Server/` using a fake `Runtime`, no absolute build-machine
paths in the bundle, and implementation plan checkboxes updated.

## Building and testing

```
xcodebuild -scheme Quail -configuration Debug build
xcodebuild -scheme Quail test
```

## Reporting issues

Use the bug report or feature request templates. For anything
security-relevant, see [SECURITY.md](SECURITY.md) instead of filing a public
issue.
