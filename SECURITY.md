# Security Policy

Quail runs local LLM inference servers as child processes and can bind a
listening socket to your LAN. Please report security issues privately rather
than filing a public GitHub issue.

## Reporting a vulnerability

Email **security@datoos.com** with a description of the issue, steps to
reproduce, and the Quail version (see About). We aim to acknowledge within 5
business days.

## Scope

In scope: the Quail app itself — process supervision, the model store,
downloader, Keychain/config handling, and the packaged binaries in
`Vendor/`. Out of scope: vulnerabilities in llama.cpp, oMLX or Rapid-MLX
themselves — please report those upstream — unless Quail's use of them
introduces a distinct issue (e.g. an insecure default flag).

## Supported versions

Only the latest released version is supported during pre-1.0 development.
