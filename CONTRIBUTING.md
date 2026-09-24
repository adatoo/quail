# Contributing to Quail

Quail is pre-alpha and developed in the open. The process below applies to
everyone, maintainers included.

## Before you start

Read [AGENTS.md](AGENTS.md) for conventions, build commands and the
definition of done, then [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) for the design and
what's next. [docs/DECISIONS.md](docs/DECISIONS.md) explains why things are
the way they are — add a new `D-nnn` entry whenever you change a decision
recorded there.

## Workflow

1. Branch from `main`: `feat/…`, `fix/…`, `ci/…` or `chore/…`.
2. Keep commits scoped and use [Conventional Commits](https://www.conventionalcommits.org/)-style
   messages (`feat:`, `fix:`, `docs:`, `chore:`, `test:`).
3. Give the PR a Conventional Commits **title** — it decides the version
   bump (ADR D-024):

   | Title | Bump |
   | --- | --- |
   | `feat: …` / `feat(scope): …` | minor |
   | `fix:`, `perf:`, `refactor:`, `docs:`, `test:`, `build:`, `ci:`, `chore:`, `revert:`, `style:` | patch |
   | `type!: …`, or `BREAKING CHANGE:` in the body | major (minor while 0.x) |

4. Bump the version **in the PR**: `PR_TITLE="<PR title>" task version:bump`.
   It sets `project.yml`'s `MARKETING_VERSION` and build number from `main`'s,
   cuts `CHANGELOG.md`'s `[Unreleased]` into the new version's section, and
   regenerates the Xcode project. Commit the result. `1.0.0` is a deliberate
   `TARGET=1.0.0 task version:bump`.
5. Open the PR against `main` with auto-merge on (`gh pr merge --auto --merge`;
   the Auto-merge workflow does this too when `BOT_TOKEN` is set). It merges
   itself once `build-and-test` and `version` pass.
6. `main` accepts changes only through PRs, merged with a **merge commit** —
   no squash, no rebase, no force-push, no direct pushes (admins included).
7. Every merge is a release: the Release workflow tags the merge commit
   `vX.Y.Z` and publishes a GitHub Release with that CHANGELOG section (a
   pre-release while 0.x); the signed DMG is attached when
   `vars.SIGNING_ENABLED` is `true`.

If `main` moves while your PR is open, merging it in conflicts on the version
lines: take `main`'s side, re-run `PR_TITLE="<PR title>" task version:bump`,
and commit — the `version` check tells you when it's needed.

## Definition of done

See the "Definition of done for a task" section in [AGENTS.md](AGENTS.md):
zero warnings on both schemes, unit tests for new logic in `Models/`,
`DeviceFit/` and `Server/` using a fake `Runtime`, no absolute build-machine
paths in the bundle, and implementation plan checkboxes updated.

## Building and testing

Install [Task](https://taskfile.dev) (`brew install go-task`), then:

```
task            # list every task
task doctor     # check the tools you need
task ci         # exactly what CI runs — do this before opening a PR
task build      # or just: build, test
task test
```

Builds go in `./DerivedData`, so they never overwrite an app Xcode (or you) has running.

`task build` compiles **unsigned**, as CI does, so macOS refuses to open the result ("Quail is damaged":
the bundle has no valid signature). To run your changes use `task install` (Release, ad-hoc signed, into
`~/Apps`; quit Quail first), or run from Xcode.
Xcode's own build phases call `task embed:*`, so building in Xcode needs go-task installed too.

Debug builds are ad-hoc signed by default, so macOS Keychain treats every
rebuild as a new app and asks for your login password when Quail reads its
stored API key. If you have a signing certificate, copy
`Config/LocalSigning.local.xcconfig.example` to
`Config/LocalSigning.local.xcconfig` (gitignored), fill in your team, and run
`xcodegen generate`; click "Always Allow" once and it sticks across rebuilds.

## Reporting issues

Use the bug report or feature request templates. For anything
security-relevant, see [SECURITY.md](SECURITY.md) instead of filing a public
issue.
