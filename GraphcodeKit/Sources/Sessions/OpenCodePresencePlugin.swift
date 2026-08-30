import Foundation

/// The plugin an OpenCode session runs to report what it is doing — the fourth shape of
/// the problem `PresenceHooks` solves for the other three backends.
///
/// OpenCode has no hook flags and no `notify` override; it has a plugin API whose events
/// cover every edge the graph reads: `session.status`/`session.idle` for the turn,
/// `tool.execute.before` for what the turn is doing, `permission.asked` for the one
/// state the other backends can only infer, and `session.created` for the id a reboot
/// resumes from. All of it writes into the same session-owned label store Claude Code's
/// hooks write to, so `ZmxSessionLauncher.presence(of:)` and `.activity(of:)` read an
/// OpenCode loop with no code of their own.
///
/// **Why a plugin and not the terminal stream.** OpenCode redraws its TUI continuously;
/// scanning it for prompts would be the heuristic tier of docs/04-cli-backends.md, and
/// the plugin is the reported one.
///
/// **Where it lands.** Written by `PresenceHooks.write(forBackend: .openCode)` beside the
/// config file that names it, and delivered through `OPENCODE_CONFIG` — the one route
/// that merges over the user's own config rather than replacing it. Guarded on
/// `$ZMX_SESSION` so a session graphcode didn't start is a no-op, and every write is
/// best-effort: a plugin that throws would surface as an error over the human's own turn.
///
/// Events verified against OpenCode 1.18.21 with a probe plugin, not read off the docs:
/// `session.status` carries `{type: "busy" | "idle" | "retry"}`, `message.updated`
/// carries the message's `role`, `tokens` and `time.completed`, and a sub-agent's session
/// arrives with a `parentID` — which is why every reading is filtered to the session the
/// loop itself opened, exactly as `SubagentStop` is left out of Claude Code's hooks.
enum OpenCodePresencePlugin {
  static func remoteSource(zmxPath: String) -> String {
    source(
      zmxPath: zmxPath,
      sessionsDirectoryExpression: #"join(process.env.HOME ?? "", ".graphcode", "sessions")"#)
  }

  /// The plugin source, with the paths only this machine can know baked in.
  static func source(zmxPath: String, sessionsDirectory: String) -> String {
    source(zmxPath: zmxPath, sessionsDirectoryExpression: jsString(sessionsDirectory))
  }

  private static func source(zmxPath: String, sessionsDirectoryExpression: String) -> String {
    """
    // Written by graphcode. Reports what this session is doing, for its card in the graph.
    import { spawnSync } from "node:child_process"
    import { appendFileSync, mkdirSync, writeFileSync } from "node:fs"
    import { join } from "node:path"

    const ZMX = \(jsString(zmxPath))
    const SESSIONS = \(sessionsDirectoryExpression)
    const PREFIX = \(jsString(SurfaceRef.zmxSessionPrefix))

    export const GraphcodePresence = async ({ directory }) => {
      const session = process.env.ZMX_SESSION
      if (!session || !session.startsWith(PREFIX)) return {}
      const nodeID = session.slice(PREFIX.length)
      const set = (...labels) => {
        try { spawnSync(ZMX, ["set", session, ...labels], { stdio: "ignore" }) } catch {}
      }
      const encode = (phrase) =>
        phrase.slice(0, 64).replace(/_/g, "_5F").replace(/[^A-Za-z0-9._-]+/g, " ").trim()
          .replace(/ /g, "_20")
      const leaf = (path) => String(path ?? "").split("/").filter(Boolean).pop() ?? ""
      const phrase = (tool, args) => {
        const a = args ?? {}
        switch (tool) {
          case "edit": case "write": case "patch": case "multiedit":
            return a.filePath ? "editing " + leaf(a.filePath) : "editing files"
          case "read": return a.filePath ? "reading " + leaf(a.filePath) : "reading"
          case "bash": return a.command ? "running " + a.command : "running a command"
          case "grep": return a.pattern ? "searching for " + a.pattern : "searching"
          case "glob": return a.pattern ? "looking for " + a.pattern : "looking for files"
          case "list": return a.path ? "listing " + leaf(a.path) : "listing files"
          case "websearch": return a.query ? "searching the web for " + a.query : "searching the web"
          case "webfetch": return a.url ? "reading " + String(a.url).replace(/^.*?\\/\\//, "").split("/")[0] : "reading a page"
          case "task": return a.description ? "delegating " + a.description : "delegating"
          case "skill": return a.name ? "running the " + a.name + " skill" : "running a skill"
          case "todowrite": case "todoread": return "planning"
          default: return "using " + tool.replace(/^.*_/, "")
        }
      }

      let main = null
      let input = 0
      let output = 0
      const counted = new Set()
      const owns = (id) => main === null || id === main
      const bank = (id) => {
        try {
          mkdirSync(SESSIONS, { recursive: true })
          const stamp = Math.floor(Date.now() / 1000)
          appendFileSync(join(SESSIONS, nodeID + ".history"), `${stamp} ${id} ${directory}\\n`)
          writeFileSync(join(SESSIONS, nodeID + ".id"), id)
        } catch {}
      }

      set("presence=idle", "activity=")
      return {
        event: async ({ event }) => {
          const p = event.properties ?? {}
          switch (event.type) {
            case "session.created":
              if (p.info?.parentID) return
              if (main === null) { main = p.info?.id ?? p.sessionID ?? null; if (main) bank(main) }
              set("presence=busy")
              return
            case "session.status":
              if (!owns(p.sessionID)) return
              if (p.status?.type === "idle") set("presence=idle", "activity=")
              else set("presence=busy")
              return
            case "session.idle":
              if (owns(p.sessionID)) set("presence=idle", "activity=")
              return
            case "permission.asked":
              if (owns(p.sessionID)) set("presence=awaitingInput")
              return
            case "permission.replied":
              if (owns(p.sessionID)) set("presence=busy")
              return
            case "message.updated": {
              const info = p.info ?? {}
              if (!owns(info.sessionID ?? p.sessionID)) return
              if (info.role === "user") { set("presence=busy"); return }
              if (info.role !== "assistant" || !info.time?.completed || counted.has(info.id)) return
              counted.add(info.id)
              const t = info.tokens ?? {}
              input += (t.input ?? 0) + (t.cache?.read ?? 0) + (t.cache?.write ?? 0)
              output += (t.output ?? 0) + (t.reasoning ?? 0)
              if (input + output > 0) set(`usage=input.${input}_output.${output}`)
              return
            }
            default:
              return
          }
        },
        "tool.execute.before": async (input, output) => {
          if (!owns(input.sessionID)) return
          if (input.tool === "question") { set("presence=awaitingInput"); return }
          set("presence=busy", "activity=" + encode(phrase(input.tool, output.args)))
        },
        "tool.execute.after": async (input) => {
          if (owns(input.sessionID) && input.tool === "question") set("presence=busy")
        },
      }
    }
    """
  }

  /// The config OpenCode is pointed at through `OPENCODE_CONFIG`: nothing but the plugin,
  /// so it adds to whatever the user configured and overrides none of it.
  static func config(pluginPath: String) -> String {
    "{\"plugin\": [\(jsString(pluginPath))]}"
  }

  /// A JSON string literal, which is also a JS one. A path containing a quote or a
  /// backslash is a path, not a syntax error.
  static func jsString(_ value: String) -> String {
    let data =
      (try? JSONSerialization.data(withJSONObject: [value], options: .withoutEscapingSlashes))
      ?? Data()
    let array = String(decoding: data, as: UTF8.self)
    return String(array.dropFirst().dropLast())
  }
}
