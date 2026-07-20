import Foundation

// claudehud-emitter — the data half of ClaudeHUD, embedded in the app bundle.
// Subcommands mirror Simple-Claude-Widget's emitter scripts:
//   hook        stdin: Claude Code hook payload  -> sessions/<id>.json
//   statusline  stdin: statusline JSON           -> limits.json + statusline text
//   usage       fetches rate limits via OAuth    -> limits.json
//   install     wires hooks + statusline into ~/.claude/settings.json

switch CommandLine.arguments.dropFirst().first {
case "hook":
    runHook()
case "statusline":
    runStatusline()
case "usage":
    runUsage()
case "install":
    runInstall()
default:
    print("usage: claudehud-emitter <hook|statusline|usage|install>")
    exit(64)
}
