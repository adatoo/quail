#if !APPSTORE
    import AppKit
    import Foundation
    import IOKit.ps

    /// Keeps a laptop awake with its lid closed while Quail's server runs and it's plugged in (ADR D-054).
    /// macOS sleeps on lid close whatever assertions an app holds; the only general switch is
    /// `pmset disablesleep`, which needs root. So, once per Quail launch, one administrator prompt starts a
    /// small root shell loop that:
    /// - sets `disablesleep 1` only while the server runs *and* the Mac is on AC power, and back to 0
    ///   otherwise (unplug it and it can sleep again, within a few seconds);
    /// - ends — restoring `disablesleep 0` — when Quail quits or crashes (it watches Quail's process), or
    ///   when this option is turned off (it watches a flag file only this user can remove).
    /// Nothing is installed. A reboot while it's on leaves the setting behind; the next launch notices
    /// (`recoverIfLeftOn`) and offers to put it back.
    @MainActor
    final class LidSleepGuard {
        enum State: Equatable {
            case off
            /// The loop is running; `sleepDisabled` is what `pmset` reports right now.
            case on
            case failed(String)
        }

        private(set) var state: State = .off
        private let directory: URL
        private let processID: Int32

        init(directory: URL = Paths.applicationSupport, processID: Int32 = ProcessInfo.processInfo.processIdentifier) {
            self.directory = directory
            self.processID = processID
        }

        var enabledFlag: URL {
            directory.appendingPathComponent("lid-awake.enabled")
        }

        var servingFlag: URL {
            directory.appendingPathComponent("lid-awake.serving")
        }

        /// Starts the loop (asking for an administrator's password), or does nothing if it's running.
        func start() {
            guard state != .on else { return }
            guard [enabledFlag, servingFlag].allSatisfy({ Self.isSafePath($0.path) }) else {
                state = .failed("the Quail folder's path has characters Quail won't pass to a shell")
                return
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: enabledFlag.path, contents: Data())
                try Self.runAsAdministrator(
                    Self.loopScript(enabled: enabledFlag, serving: servingFlag, processID: processID),
                    prompt: "Quail wants to keep this Mac awake with the lid closed while its server runs and it's plugged in."
                )
                state = .on
            } catch {
                try? FileManager.default.removeItem(at: enabledFlag)
                state = .failed((error as? GuardError)?.message ?? error.localizedDescription)
            }
        }

        /// Ends the loop; it restores sleep within a few seconds. No password needed.
        func stop() {
            try? FileManager.default.removeItem(at: enabledFlag)
            try? FileManager.default.removeItem(at: servingFlag)
            if state != .off {
                state = .off
            }
        }

        /// Tells the loop whether the server is running.
        func setServing(_ serving: Bool) {
            if serving {
                FileManager.default.createFile(atPath: servingFlag.path, contents: Data())
            } else {
                try? FileManager.default.removeItem(at: servingFlag)
            }
        }

        /// At launch: a flag left from a run whose loop never finished (a reboot, a killed loop) means sleep
        /// may still be disabled. If `pmset` says so, ask to restore it (the same kind of prompt).
        func recoverIfLeftOn() {
            let leftOver = FileManager.default.fileExists(atPath: enabledFlag.path)
            try? FileManager.default.removeItem(at: enabledFlag)
            try? FileManager.default.removeItem(at: servingFlag)
            guard leftOver, Self.sleepDisabled else { return }
            try? Self.runAsAdministrator(
                "/usr/bin/pmset -a disablesleep 0",
                prompt: "Quail left sleep turned off (for the lid-closed option) when it last quit unexpectedly. Enter your password to turn sleep back on."
            )
        }

        // MARK: System facts

        /// Whether `pmset` reports sleep disabled (`SleepDisabled 1`), which any user can read.
        static var sleepDisabled: Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return output.split(separator: "\n").contains { line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                return fields.first == "SleepDisabled" && fields.last == "1"
            }
        }

        /// Whether the Mac is running on AC power (a desktop always is).
        static var onACPower: Bool {
            guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                  let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
            else { return true }
            return type == kIOPMACPowerKey
        }

        // MARK: The loop

        struct GuardError: Error {
            let message: String
        }

        /// The root loop. Paths are quoted for `sh`; `runAsAdministrator` refuses any that could break out.
        static func loopScript(enabled: URL, serving: URL, processID: Int32) -> String {
            """
            E="\(enabled.path)"; S="\(serving.path)"; P=\(processID); cur=-1
            while /bin/kill -0 $P 2>/dev/null && [ -f "$E" ]; do
              want=0
              if [ -f "$S" ] && /usr/bin/pmset -g ps | /usr/bin/grep -q "AC Power"; then want=1; fi
              if [ "$want" != "$cur" ]; then /usr/bin/pmset -a disablesleep $want; cur=$want; fi
              /bin/sleep 3
            done
            /usr/bin/pmset -a disablesleep 0
            /bin/rm -f "$E" "$S"
            """
        }

        /// A path that can sit inside the loop's double-quoted `sh` strings: nothing that ends or expands them.
        static func isSafePath(_ path: String) -> Bool {
            !path.contains(where: { "\"$`\\\n".contains($0) })
        }

        /// Runs `script` as root in the background through `do shell script … with administrator
        /// privileges` (the system's own password prompt), returning once it has started.
        static func runAsAdministrator(_ script: String, prompt: String) throws {
            let command = "/bin/sh -c " + shellQuoted(script) + " > /dev/null 2>&1 &"
            let source = "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges"
            var error: NSDictionary?
            guard let appleScript = NSAppleScript(source: source) else {
                throw GuardError(message: "couldn't prepare the request")
            }
            appleScript.executeAndReturnError(&error)
            if let error {
                let number = error[NSAppleScript.errorNumber] as? Int
                throw GuardError(message: number == -128
                    ? "cancelled — no password was entered"
                    : (error[NSAppleScript.errorMessage] as? String) ?? "the request failed")
            }
        }

        /// `'…'` for `sh`, with any `'` inside closed, escaped and reopened.
        static func shellQuoted(_ text: String) -> String {
            "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        /// An AppleScript string literal.
        static func appleScriptString(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
    }
#endif
