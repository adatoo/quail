# ADR-0022: swift-argument-parser for the `quail` CLI

**Date:** 2026-09-23 · **Status:** Accepted

**Decision:** The `quail` command-line tool uses Apple's `swift-argument-parser` (SPM), linked into the CLI target only — never the app.
**Alternatives:** Hand-written argument parsing (no dependency).
**Why:** A CLI with ~12 subcommands, flags and generated `--help` is exactly what the package exists for; hand-rolled parsing would be more code to get wrong for help text, errors and completions. It's Apple-maintained, source-only and has no transitive dependencies. User decision.
**Trade-off:** The first dependency beyond Sparkle — AGENTS.md's rule now reads "Sparkle and swift-argument-parser (CLI only)".
**Revisit if:** the package ever pulls in transitive dependencies.
