# Oracle for tools/ci-openurl-window.sh on Windows (ENG-55).
#
# Finds the process a ShellExecuteW launch started and prints its command line
# when that line holds the URL BYTE FOR BYTE as one token: preceded by a space
# or a quote (or nothing) and followed by a space, a quote or the end. A
# browser that got the URL split at '&', or with '%20' decoded, fails.
#
# The URL is read from a file, never from the command line, so neither bash,
# cmd nor PowerShell gets a chance to rewrite it before the comparison.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File win-browser-cmdline.ps1 -UrlFile u.txt
#
# Prints BROWSER_CMDLINE pid=<pid> name=<exe> + BROWSER_CMDLINE_TEXT <line> and
# exits 0, or prints BROWSER_CMDLINE_NONE and exits 1 after -TimeoutMs.
param(
  [Parameter(Mandatory = $true)][string]$UrlFile,
  [int]$TimeoutMs = 15000
)
$url = [IO.File]::ReadAllText($UrlFile)
if ($url.Length -eq 0) { "BROWSER_CMDLINE_NONE (empty URL file)"; exit 1 }
# The engine itself carries the URL in --initial-url; it is not the browser.
$skip = @('rn-impeller.exe', 'powershell.exe', 'pwsh.exe', 'bash.exe', 'cmd.exe')
$deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
while ([DateTime]::UtcNow -lt $deadline) {
  foreach ($p in Get-CimInstance Win32_Process) {
    $cl = $p.CommandLine
    if (-not $cl -or $skip -contains $p.Name) { continue }
    $i = $cl.IndexOf($url, [StringComparison]::Ordinal)
    if ($i -lt 0) { continue }
    $end = $i + $url.Length
    $before = if ($i -gt 0) { $cl[$i - 1] } else { ' ' }
    $after = if ($end -lt $cl.Length) { $cl[$end] } else { ' ' }
    if (($before -eq ' ' -or $before -eq '"') -and ($after -eq ' ' -or $after -eq '"')) {
      "BROWSER_CMDLINE pid=$($p.ProcessId) name=$($p.Name)"
      "BROWSER_CMDLINE_TEXT $cl"
      exit 0
    }
  }
  Start-Sleep -Milliseconds 100
}
"BROWSER_CMDLINE_NONE (no process held the URL as one token within $TimeoutMs ms)"
exit 1
