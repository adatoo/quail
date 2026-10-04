# Security Policy

Quail runs a local LLM inference server as a child process (`quail-server`, or
the bundled `llama-server`) and can bind a listening socket to your LAN.
Please report security issues privately rather than filing a public GitHub
issue.

## Reporting a vulnerability

Email **security@datoos.com** with a description of the issue, steps to
reproduce, and the Quail version (see About). We aim to acknowledge within 5
business days.

## Scope

In scope: the Quail app, `quail-server` and the `quail` command — the HTTP
API and its API-key and Origin checks, process supervision, the model store,
the downloader, Keychain/config handling, updates, and how the bundled
binaries are built and packaged. Out of scope: vulnerabilities in llama.cpp,
MLX (mlx-swift, mlx-swift-lm) or Sparkle themselves — please report those
upstream — unless Quail's use of them introduces a distinct issue (e.g. an
insecure default flag).

## Supported versions

Only the latest released version is supported. Every fix ships as a new
release, which installed copies update to.
