# ADR-0054: Keeping the Mac awake while the server runs, and with a laptop's lid closed

**Date:** 2026-09-27 · **Status:** Accepted

**Decision:** Settings → General → Power, plus a menu toggle, "Keep this Mac awake while the server runs". It's off by default.
- **The assertion:** while the server is starting or ready, Quail holds one `kIOPMAssertPreventUserIdleSystemSleep` power assertion (`KeepAwake`), the kind `caffeinate -i` takes, named "Quail is serving a local model…" in `pmset -g assertions`. It's released when the server stops, the setting goes off, or Quail quits. The display can still turn off. It needs no password or install, and it's allowed in the App Store build.
- **The lid-closed option (direct build only), "Also with the lid closed, when plugged in":** macOS sleeps a laptop when its lid closes whatever assertions an app holds; the header says so for this assertion type, and the old `PreventSystemSleep` type is unsupported. The only general switch is `pmset disablesleep`, which needs root. So `LidSleepGuard` asks once per launch, when the server first starts, through `do shell script … with administrator privileges` (the system's own password prompt), and starts a small root shell loop:
  - The loop sets `disablesleep 1` only while a "serving" flag file exists and `pmset -g ps` says AC Power, and `disablesleep 0` otherwise, every 3 seconds. Unplugging brings sleep back.
  - It ends when Quail's process is gone (quit or crash) or its "enabled" flag file is removed (the option turned off, or Quail quitting cleanly), and restores `disablesleep 0` on the way out.
  - Nothing is installed. The flag files live in `Application Support/Quail`, and paths that could break the loop's quoting are refused.
  - A reboot while it's on leaves `SleepDisabled 1` and the flag behind. The next launch sees both (`recoverIfLeftOn`) and asks for the password to restore sleep.

**Why:** requested. Utilities that do this have to be installed; built in, it's one switch, and it can follow the server's state. The user chose "while the server runs" over "while a model is busy" (pauses between an agent's requests would let the Mac sleep) and over a manual toggle, and chose the guarded lid-closed option.

**Safety:** a closed laptop running a model gets warm in a bag. That's why the lid-closed option runs only on AC power, only while the server runs, ends with Quail, and says so beside the switch.

**Alternatives:**
- A privileged helper daemon (`SMAppService.daemon`): a persistent root component to install, sign and update, for one command.
- Asking for the password at every server start and stop, which is tiresome.
- Clamshell mode: it needs an external display and keyboard, so it isn't general.

**Revisit if:** macOS offers a public lid-close assertion. (The legacy App Store configuration leaves the lid-closed option out, since the sandbox can't run `do shell script` as root; Store publication is cancelled by ADR-0053.)
