// TEMPORARY stress probe, stress branch only. Prints the real codespaceScript for a schedule.
import Foundation

let args = CommandLine.arguments
let free = Int(args[1])!
let holdUntil = Int(args[2])!
let pauseAfter = Int(args[3])!
let log = args[4]
let marker = args[5]
let dial = "(echo dial >> '\(log)'; exit 1)"
print(
  SSHReconnectLoop.codespaceScript(
    connect: dial, reconnect: dial, pauseMarker: marker,
    schedule: CodespaceDialSchedule(
      freeRetryWindow: free, holdUntil: holdUntil, pauseAfter: pauseAfter)))
