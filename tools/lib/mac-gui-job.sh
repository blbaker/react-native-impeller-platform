# shellcheck shell=bash
# Run a script in the logged-in user's GUI (Aqua) session, from SSH, on the Mac.
# Why: codesign with an "Apple Development" identity fails from an SSH session
# (errSecInternalComponent: the login keychain belongs to the GUI security
# session); a launchd job bootstrapped into gui/<uid> runs in that session and
# signs (measured). The GUI session must exist (someone logged in at the Mac).
#
#   mac_gui_run <script> <log> <timeout_s>
#     runs `bash <script>` as a one-shot launchd job (label unique per call),
#     waits for the script to finish, removes the job, and returns the
#     script's exit code (124 on timeout). The script's stdout+stderr go to
#     <log>. The job's environment: HOME, a PATH with Homebrew, nothing else.
mac_gui_run() {
  local script="$1" log="$2" timeout="$3"
  local uid label plist rcfile i
  uid=$(id -u)
  label="dev.rnimpeller.gui-job.$$.$RANDOM"
  plist="$(dirname "$log")/$label.plist"
  rcfile="$log.rc"
  rm -f "$rcfile"
  : > "$log"
  cat > "$plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>-c</string>
    <string>bash "$script"; echo \$? > "$rcfile"</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
  </dict>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
  if ! launchctl bootstrap "gui/$uid" "$plist" 2>> "$log"; then
    echo "mac-gui-job: launchctl bootstrap gui/$uid failed (is anyone logged in at the Mac?)" >> "$log"
    rm -f "$plist"
    return 1
  fi
  for ((i = 0; i < timeout * 2; i++)); do
    [ -s "$rcfile" ] && break
    sleep 0.5
  done
  launchctl bootout "gui/$uid/$label" 2> /dev/null
  rm -f "$plist"
  [ -s "$rcfile" ] || { echo "mac-gui-job: timed out after ${timeout}s" >> "$log"; return 124; }
  return "$(cat "$rcfile")"
}
