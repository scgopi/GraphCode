import Foundation

/// Translates a `LoopGraph` into the Goobers orchestration DSL
/// (`goobers.dev/v1alpha1`, `dslVersion: "2.0"`) — the config-as-code a Goobers
/// instance runs unattended on a server, rather than the canvas GraphCode drives
/// on this machine.
///
/// The two models agree on the hard part and disagree on the easy parts. Both bound
/// their cycles by construction: GraphCode refuses an unguarded `CycleGuard`
/// (`CycleGuard.isBounded`), Goobers meters repasses. What differs is where the
/// information lives — GraphCode hangs a condition on the *edge*, Goobers demands a
/// `Gate` *state*; GraphCode fuses persona and work into one `LoopNode`, Goobers
/// splits them into a `Goober` and a `Task`.
///
/// So export is a graph rewrite, not a field copy, and some graphs simply have no
/// image on the other side. Those are refused by name (`ExportDiagnostic`) rather
/// than silently flattened: a workflow that quietly dropped an edge would run
/// unattended on a server doing something its author never drew.
public enum GoobersExport {

  // MARK: - Diagnostics

  /// A construct that cannot cross into the Goobers DSL, named precisely enough that
  /// the author knows which node or edge to change.
  ///
  /// Everything here is a hard error. There is deliberately no "lossy export" mode:
  /// the failure of a dropped edge shows up as a server-side agent doing the wrong
  /// thing hours later, which is exactly the debugging session the type exists to
  /// prevent.
  public enum ExportDiagnostic: Equatable, Sendable {
    case emptyGraph
    case noEntryPoint
    case unsupportedBackend(node: String, backend: CLISessionBackendKind)
    case messageEdge(from: String, to: String)
    case spawnEdge(from: String, to: String)
    case compositeNode(node: String)
    case sketchNode(node: String)
    case fanOut(node: String, targets: [String])
    case unboundedCycle(from: String, to: String)
    case danglingEdge
    case timeBasedNode(node: String)
    case multipleEntryPoints(nodes: [String])
    case adaptiveCycleGuard(from: String, to: String)

    public var message: String {
      switch self {
      case .emptyGraph:
        return "The graph has no nodes; there is no workflow to export."
      case .noEntryPoint:
        return """
          The graph has no entry point — every node is handed off to by another. \
          A Goobers workflow needs a single `start` state, so at least one node must \
          begin the run.
          """
      case .unsupportedBackend(let node, let backend):
        return """
          Node “\(node)” runs on the \(backend.rawValue) backend, which has no Goobers \
          harness. Goobers supports `copilot` and `claude-code`; switch the node's \
          backend or export it as a deterministic task.
          """
      case .messageEdge(let from, let to):
        return """
          The message edge “\(from)” → “\(to)” has no Goobers equivalent. Messages \
          inject into a peer's live session; Goobers tasks communicate through \
          declared outputs (`inputsFrom`), not by interrupting each other.
          """
      case .spawnEdge(let from, let to):
        return """
          The spawn edge “\(from)” → “\(to)” has no Goobers equivalent — DSL 2.0 has \
          no child-workflow construct, so a node cannot instantiate another graph.
          """
      case .compositeNode(let node):
        return """
          Node “\(node)” is a composite holding a sub-graph. DSL 2.0 has no nested \
          workflows; flatten it into the parent graph before exporting.
          """
      case .sketchNode(let node):
        return """
          Node “\(node)” is still a sketch. Promote it to a real loop — a sketch has \
          no backend or goal to translate.
          """
      case .fanOut(let node, let targets):
        return """
          Node “\(node)” hands off to \(targets.count) nodes \
          (\(targets.map { "“\($0)”" }.joined(separator: ", "))). Goobers expresses \
          parallelism as a declared `parallels[]` block with a single `join`, which \
          this exporter does not yet synthesize. Serialize the branches, or wait for \
          fan-out support.
          """
      case .unboundedCycle(let from, let to):
        return """
          The edge “\(from)” → “\(to)” closes a cycle with no guard, so it would fire \
          once and leave the loop inert. Attach a cycle guard — its bound becomes the \
          workflow's repass budget.
          """
      case .danglingEdge:
        return "An edge refers to a node that is not in the graph."
      case .timeBasedNode(let node):
        return """
          Node “\(node)” is a time-based loop, whose cadence re-enters a session that \
          is already running. A Goobers `type: schedule` trigger starts a *new* run \
          instead, so exporting this would silently turn “keep going” into “start \
          again”. Convert it to a goal- or turn-based node, or drive the repetition \
          with a cycle guard, whose bound does become a repass budget.
          """
      case .multipleEntryPoints(let nodes):
        return """
          The graph has \(nodes.count) entry points \
          (\(nodes.map { "“\($0)”" }.joined(separator: ", "))). A Goobers workflow has \
          one start state; preserving several roots requires a parallel block and join, \
          which this exporter does not synthesize yet.
          """
      case .adaptiveCycleGuard(let from, let to):
        return """
          The cycle guard on “\(from)” → “\(to)” uses an `until` condition or plateau \
          detection. Goobers DSL 2.0 only preserves the count as `maxRepasses`; exporting \
          this guard would silently drop an early-stop rule. Use a count-only guard for \
          now.
          """
      }
    }
  }

  public struct ExportError: Error, Equatable, Sendable {
    public let diagnostics: [ExportDiagnostic]
    public init(_ diagnostics: [ExportDiagnostic]) { self.diagnostics = diagnostics }
    public var localizedDescription: String {
      diagnostics.map(\.message).joined(separator: "\n\n")
    }
  }

  // MARK: - Result

  /// The emitted config tree, as paths relative to the source root a Goobers instance
  /// points `config/` at. Returned as text rather than written so the caller decides
  /// where it lands — and so tests can assert on the YAML without touching a disk.
  public struct Bundle: Equatable, Sendable {
    public var files: [String: String]
    public init(files: [String: String]) { self.files = files }
  }

  // MARK: - Entry point

  /// Translate `graph` into a Goobers config tree.
  ///
  /// - Parameters:
  ///   - graph: the canvas graph to translate.
  ///   - workflowName: DNS-style name for the emitted `Workflow`.
  ///   - gaggleName: the gaggle this workflow belongs to.
  ///   - project: the repository the gaggle targets, as `owner/name`.
  /// - Throws: `ExportError` listing every construct that cannot be represented. All
  ///   diagnostics are collected before throwing, so one export reports every problem
  ///   rather than making the author re-run to find the next one.
  public static func export(
    graph: LoopGraph,
    workflowName: String,
    gaggleName: String,
    project: ProjectCoordinates
  ) throws -> Bundle {
    let plan = try plan(graph: graph, workflowName: workflowName, gaggleName: gaggleName)

    var files: [String: String] = [:]
    files["manifest.yaml"] = renderManifest(gaggleName: gaggleName)
    files["instance.yaml.example"] = renderInstanceExample(project: project)
    files["gaggles/\(gaggleName)/gaggle.yaml"] = renderGaggle(
      gaggleName: gaggleName, project: project)
    files["gaggles/\(gaggleName)/workflows/\(workflowName).yaml"] = renderWorkflow(plan)
    for role in plan.roles {
      let dir = "gaggles/\(gaggleName)/goobers/\(role.name)"
      files["\(dir)/goober.yaml"] = renderGoober(
        role, gaggleName: gaggleName, workflowName: workflowName)
      files["\(dir)/instructions.md"] = renderInstructions(role)
    }
    return Bundle(files: files)
  }

  /// The live instance file paired with an exported source tree. It is separate from
  /// `instance.yaml.example` because Goobers' source-tree validator expects the example
  /// at the export root, while a running instance expects this file beside `config/`.
  ///
  /// Port zero asks the OS for a free loopback port. Goobers writes the chosen address
  /// to `scheduler/api.address`, which is the only address GraphCode trusts.
  public static func runtimeInstance(
    project: ProjectCoordinates,
    apiListen: String = "127.0.0.1:0"
  ) -> String {
    """
    api:
      listen: \(apiListen)
    apiVersion: goobers.dev/v1alpha1
    kind: Instance
    repos:
      - provider: github
        owner: \(project.owner)
        name: \(project.name)
        token:
          env: GOOBERS_GITHUB_TOKEN
    runConditions:
      maxParallelRuns: 1
    telemetry:
      enabled: true

    """
  }

  /// Where the gaggle's work lives. Separate from `ProjectRef` because a GraphCode
  /// project is a local directory, and a gaggle targets a hosted repository — the
  /// local path says nothing about the owner or branch a server needs.
  public struct ProjectCoordinates: Equatable, Sendable {
    public var owner: String
    public var name: String
    public var branch: String
    public init(owner: String, name: String, branch: String = "main") {
      self.owner = owner
      self.name = name
      self.branch = branch
    }
  }

  // MARK: - Plan

  struct Role: Equatable {
    var name: String
    var displayName: String
    var instructions: String
    var harness: String
    var model: String
    var modelNote: String?
  }

  struct Task: Equatable {
    var name: String
    var goal: String
    var role: String
    var workspace: String
    var next: String?
    var timeoutSeconds: Int?
  }

  struct Gate: Equatable {
    var name: String
    var check: String
    var params: [String: String]
    var branches: [(outcome: String, target: String)]
    var maxRepasses: Int?

    static func == (lhs: Gate, rhs: Gate) -> Bool {
      lhs.name == rhs.name && lhs.check == rhs.check && lhs.params == rhs.params
        && lhs.maxRepasses == rhs.maxRepasses
        && lhs.branches.map(\.outcome) == rhs.branches.map(\.outcome)
        && lhs.branches.map(\.target) == rhs.branches.map(\.target)
    }
  }

  struct Plan: Equatable {
    var workflowName: String
    var gaggleName: String
    var displayName: String
    var start: String
    var tasks: [Task]
    var gates: [Gate]
    var roles: [Role]
  }

  // MARK: - Planning

  static func plan(
    graph: LoopGraph,
    workflowName: String,
    gaggleName: String
  ) throws -> Plan {
    var diagnostics: [ExportDiagnostic] = []

    let exportable = Array(graph.nodes.filter { $0.loopType != .sketch })
    guard !exportable.isEmpty else { throw ExportError([.emptyGraph]) }

    // Reject node kinds with no image in the DSL before planning anything, so the
    // author gets the whole list at once.
    for node in exportable {
      if node.subGraph != nil {
        diagnostics.append(.compositeNode(node: node.title))
      }
      if harness(for: node.backend) == nil {
        diagnostics.append(
          .unsupportedBackend(node: node.title, backend: node.backend))
      }
      // A time-based node's recurrence has no image in the DSL, and dropping it
      // silently would export a loop that runs exactly once.
      if node.loopType == .timeBased {
        diagnostics.append(.timeBasedNode(node: node.title))
      }
    }

    let titles = Dictionary(uniqueKeysWithValues: exportable.map { ($0.id, $0.title) })
    let names = uniqueNames(for: exportable)

    // Only handoff edges sequence; message and spawn have no equivalent at all.
    for edge in graph.edges {
      guard let from = titles[edge.from], let to = titles[edge.to] else {
        // An edge into a sketch is not an error — the sketch simply isn't exported.
        if graph.nodes[id: edge.from] == nil || graph.nodes[id: edge.to] == nil {
          diagnostics.append(.danglingEdge)
        }
        continue
      }
      switch edge.kind {
      case .message: diagnostics.append(.messageEdge(from: from, to: to))
      case .spawn: diagnostics.append(.spawnEdge(from: from, to: to))
      case .handoff: break
      }
    }

    let sequencing = Array(
      graph.edges.filter {
        $0.kind.blocksTarget && titles[$0.from] != nil && titles[$0.to] != nil
      })

    let entryIDs = graph.startAnchors.filter { titles[$0] != nil }
    if entryIDs.count > 1 {
      diagnostics.append(.multipleEntryPoints(nodes: entryIDs.compactMap { titles[$0] }))
    }

    // A cycle-closing edge must carry a guard, or it fires once and the loop the
    // author drew never actually loops.
    let backEdges = Set(cycleClosingEdgeIDs(nodes: exportable.map(\.id), edges: sequencing))
    for edge in sequencing where backEdges.contains(edge.id) {
      let bounded = edge.cycleGuard?.isBounded ?? false
      if !bounded {
        diagnostics.append(
          .unboundedCycle(from: titles[edge.from] ?? "?", to: titles[edge.to] ?? "?"))
      }
      if let guardrail = edge.cycleGuard,
        guardrail.effectiveUntil != nil
          || (guardrail.stopAfterPassesWithoutImprovement ?? 0) > 0
      {
        diagnostics.append(
          .adaptiveCycleGuard(
            from: titles[edge.from] ?? "?", to: titles[edge.to] ?? "?"))
      }
    }

    var tasks: [Task] = []
    var gates: [Gate] = []
    var roles: [String: Role] = [:]

    for node in exportable {
      guard let taskName = names[node.id] else { continue }
      let outgoing = sequencing.filter { $0.from == node.id }

      let unconditional = outgoing.filter { $0.condition == .always }
      let conditional = outgoing.filter { $0.condition != .always }

      // Phase 1 handles a single successor per outcome. Real fan-out needs a
      // `parallels[]` block with a join, which is the next slice of work.
      if unconditional.count > 1 {
        diagnostics.append(
          .fanOut(
            node: node.title,
            targets: unconditional.compactMap { titles[$0.to] }))
      }
      if !conditional.isEmpty && !unconditional.isEmpty {
        diagnostics.append(
          .fanOut(
            node: node.title,
            targets: outgoing.compactMap { titles[$0.to] }))
      }

      let role = roleName(for: node)
      if roles[role] == nil {
        roles[role] = Role(
          name: role,
          displayName: node.title,
          instructions: instructionsBody(for: node),
          harness: harness(for: node.backend) ?? "copilot",
          model: model(for: node.modelTier),
          modelNote: modelNote(for: node.modelTier))
      }

      var next: String?
      if !conditional.isEmpty {
        // Conditions live on GraphCode's edges and on Goobers' states, so every
        // conditional edge is reified into a gate the task hands off to.
        let gateName = "\(taskName)-gate"
        var branches: [(String, String)] = []
        var repasses: Int?
        for edge in conditional {
          guard let target = names[edge.to] else { continue }
          let outcome = edge.condition == .onSuccess ? "pass" : "fail"
          branches.append((outcome, target))
          if let bound = edge.cycleGuard?.maxIterations {
            repasses = max(repasses ?? 0, bound)
          }
        }
        // A gate must be able to fall through, or a run that doesn't match any
        // declared branch has nowhere to go.
        if !branches.contains(where: { $0.0 == "pass" }) {
          branches.append(("pass", "@abort"))
        }
        if !branches.contains(where: { $0.0 == "fail" }) {
          branches.append(("fail", "@abort"))
        }
        gates.append(
          Gate(
            name: gateName,
            check: "status-equals",
            params: ["equals": "success"],
            branches: branches.map { (outcome: $0.0, target: $0.1) },
            maxRepasses: repasses))
        next = gateName
      } else if let only = unconditional.first, let target = names[only.to] {
        next = target
      }

      tasks.append(
        Task(
          name: taskName,
          goal: goal(for: node),
          role: role,
          workspace: workspace(for: node),
          next: next,
          timeoutSeconds: node.goal?.stallAfterSeconds.map { Int($0) }))
    }

    guard diagnostics.isEmpty else { throw ExportError(dedupe(diagnostics)) }

    guard let startID = startNode(graph: graph, exportable: exportable),
      let start = names[startID]
    else {
      throw ExportError([.noEntryPoint])
    }

    // `tasks` follows `graph.nodes` order; lead with the start state so the emitted
    // YAML reads in execution order.
    let ordered =
      tasks.filter { $0.name == start } + tasks.filter { $0.name != start }

    return Plan(
      workflowName: workflowName,
      gaggleName: gaggleName,
      displayName: graph.scope.displayName,
      start: start,
      tasks: ordered,
      gates: gates,
      roles: roles.values.sorted { $0.name < $1.name })
  }

  // MARK: - Graph analysis

  /// Edges whose target is an ancestor of their source — the ones that close a loop.
  /// Found by DFS from the graph's entry points, marking edges that point back into
  /// the current stack.
  static func cycleClosingEdgeIDs(nodes: [UUID], edges: [LoopEdge]) -> [UUID] {
    var adjacency: [UUID: [LoopEdge]] = [:]
    for edge in edges { adjacency[edge.from, default: []].append(edge) }

    var color: [UUID: Int] = [:]  // 0 unvisited, 1 on stack, 2 done
    var closing: [UUID] = []

    func visit(_ id: UUID) {
      color[id] = 1
      for edge in adjacency[id] ?? [] {
        switch color[edge.to] ?? 0 {
        case 0: visit(edge.to)
        case 1: closing.append(edge.id)
        default: break
        }
      }
      color[id] = 2
    }

    for id in nodes where (color[id] ?? 0) == 0 { visit(id) }
    return closing
  }

  static func startNode(graph: LoopGraph, exportable: [LoopNode]) -> UUID? {
    let ids = Set(exportable.map(\.id))
    let anchors = graph.startAnchors.filter { ids.contains($0) }
    if let first = anchors.first { return first }
    // A closed cycle has no untargeted node; the graph's own anchor rule picks one
    // arbitrarily, and so do we rather than refusing to export a valid loop.
    return exportable.first?.id
  }

  // MARK: - Field mapping

  static func harness(for backend: CLISessionBackendKind) -> String? {
    switch backend {
    case .copilotCLI: return "copilot"
    case .claudeCode: return "claude-code"
    // Goobers has no harness for these; refusing beats silently retargeting a node
    // onto a model its prompt was never written for.
    case .codex, .openCode: return nil
    }
  }

  static func model(for tier: ModelTier?) -> String {
    // Deliberately always `auto`. Goobers validates `model` against the harness's
    // live catalogue (`internal/harness/copilot.go`, `claude.go`), which differs per
    // harness and changes as models ship — a name pinned here would validate on the
    // machine that exported and fail on the instance that runs it. The author's tier
    // survives as a comment on the goober, where it informs a human without
    // pretending to be a model the server has heard of.
    _ = tier
    return "auto"
  }

  /// The tier the node asked for, as a note beside the `auto` selection above.
  static func modelNote(for tier: ModelTier?) -> String? {
    guard let tier else { return nil }
    switch tier {
    case .fast: return "GraphCode tier: fast — prefers a cheaper, quicker model."
    case .standard: return "GraphCode tier: standard."
    case .capable: return "GraphCode tier: capable — prefers a stronger model."
    }
  }

  /// What the task is trying to achieve, in one line. A goal-based node already
  /// states this; anything else falls back to its instruction or title.
  static func goal(for node: LoopNode) -> String {
    if let summary = node.goal?.summary, !summary.isEmpty { return summary }
    if let check = node.checkDescription, !check.isEmpty { return check }
    if let first = node.firstInstruction, !first.isEmpty {
      return String(first.split(separator: "\n").first ?? "")
    }
    return node.title
  }

  static func workspace(for node: LoopNode) -> String {
    // A node that pauses before writes only never mutates the tree, which is exactly
    // what `repo-readonly` names. Everything else may commit.
    node.pausesBeforeWritesOnly ? "repo-readonly" : "repo"
  }

  static func roleName(for node: LoopNode) -> String {
    slug(node.title)
  }

  /// The persona file. GraphCode keeps the prompt on the node; Goobers keeps it in a
  /// markdown file beside the role, so the node's instruction becomes the body.
  static func instructionsBody(for node: LoopNode) -> String {
    var lines: [String] = []
    if let first = node.firstInstruction, !first.isEmpty {
      lines.append(first)
    } else if let trigger = node.triggerPrompt, !trigger.isEmpty {
      lines.append(trigger)
    }
    if let goal = node.goal {
      lines.append("")
      lines.append("## Done when")
      lines.append("")
      lines.append(goal.summary)
      if let predicate = goal.predicate, !predicate.isEmpty {
        lines.append("")
        lines.append("Verify with `\(predicate)`.")
      }
    }
    if lines.isEmpty { lines.append("Carry out the “\(node.title)” step.") }
    return lines.joined(separator: "\n")
  }

  // MARK: - Naming

  /// DNS-style names, because that is what the DSL's `metadata.name` accepts.
  static func slug(_ raw: String) -> String {
    var out = ""
    var lastWasDash = true  // leading dashes are invalid, so suppress them
    for character in raw.lowercased() {
      if character.isLetter || character.isNumber {
        out.append(character)
        lastWasDash = false
      } else if !lastWasDash {
        out.append("-")
        lastWasDash = true
      }
    }
    while out.hasSuffix("-") { out.removeLast() }
    return out.isEmpty ? "loop" : out
  }

  /// Node titles are free text and may collide once slugged; task names must be
  /// unique because `next` addresses them.
  static func uniqueNames(for nodes: [LoopNode]) -> [UUID: String] {
    var used: Set<String> = []
    var result: [UUID: String] = [:]
    for node in nodes {
      var candidate = slug(node.title)
      var suffix = 2
      while used.contains(candidate) {
        candidate = "\(slug(node.title))-\(suffix)"
        suffix += 1
      }
      used.insert(candidate)
      result[node.id] = candidate
    }
    return result
  }

  static func dedupe(_ diagnostics: [ExportDiagnostic]) -> [ExportDiagnostic] {
    var seen: [ExportDiagnostic] = []
    for diagnostic in diagnostics where !seen.contains(diagnostic) { seen.append(diagnostic) }
    return seen
  }

  // MARK: - Rendering

  static func renderManifest(gaggleName: String) -> String {
    """
    apiVersion: goobers.dev/v1alpha1
    kind: Manifest
    metadata:
      name: \(gaggleName)
      annotations:
        goobers.dev/allow-preview-features: "true"
    spec:
      instance:
        name: \(gaggleName)
        environment: dev
      gaggles:
        - \(gaggleName)

    """
  }

  static func renderGaggle(gaggleName: String, project: ProjectCoordinates) -> String {
    """
    apiVersion: goobers.dev/v1alpha1
    kind: Gaggle
    metadata:
      name: \(gaggleName)
    spec:
      displayName: \(yamlScalar(gaggleName))
      project:
        provider: github
        owner: \(project.owner)
        name: \(project.name)
        branch: \(project.branch)
      backlog:
        provider: github
        project: \(project.owner)/\(project.name)
        labels:
          - \(gaggleName)
      isolation:
        namespace: gaggle-\(gaggleName)

    """
  }

  /// The instance template that makes the emitted tree a valid config *source tree*,
  /// which is what `goobers validate --source-tree` checks. Holds no secret — a token
  /// ref names an environment variable, it never carries a value.
  static func renderInstanceExample(project: ProjectCoordinates) -> String {
    """
    # Template instance.yaml generated alongside this config tree. No secrets:
    # `token.env` names an environment variable, it does not hold a value.
    apiVersion: goobers.dev/v1alpha1
    kind: Instance
    repos:
      - provider: github
        owner: \(project.owner)
        name: \(project.name)
        token:
          env: GOOBERS_GITHUB_TOKEN
    telemetry:
      enabled: true

    """
  }

  static func renderGoober(_ role: Role, gaggleName: String, workflowName: String) -> String {
    var lines: [String] = [
      "apiVersion: goobers.dev/v1alpha1",
      "kind: Goober",
      "metadata:",
      "  name: \(role.name)",
      "spec:",
      "  gaggle: \(gaggleName)",
      "  role: \(role.name)",
      "  displayName: \(yamlScalar(role.displayName))",
      "  instructions: instructions.md",
      "  harness: \(role.harness)",
    ]
    if let note = role.modelNote {
      lines.append("  # \(note)")
    }
    lines.append(contentsOf: [
      "  model: \(role.model)",
      "  capabilities:",
      "    - agent:model",
      "  tools:",
      "    - shell",
      "  workflows:",
      "    - \(workflowName)",
    ])
    return lines.joined(separator: "\n") + "\n"
  }

  static func renderInstructions(_ role: Role) -> String {
    """
    ---
    role: \(role.name)
    description: \(yamlScalar(role.displayName))
    ---

    # \(role.displayName)

    \(role.instructions)

    """
  }

  static func renderWorkflow(_ plan: Plan) -> String {
    var lines: [String] = [
      "# Generated by GraphCode from a loop graph. Edits here are not carried back.",
      "apiVersion: goobers.dev/v1alpha1",
      "kind: Workflow",
      "dslVersion: \"2.0\"",
      "metadata:",
      "  name: \(plan.workflowName)",
      "spec:",
      "  gaggle: \(plan.gaggleName)",
      "  displayName: \(yamlScalar(plan.displayName))",
      "  triggers:",
      "    - type: manual",
      "  start: \(plan.start)",
      "  tasks:",
    ]

    for task in plan.tasks {
      lines.append("    - name: \(task.name)")
      lines.append("      type: agentic")
      lines.append("      goober: \(task.role)")
      lines.append("      goal: \(yamlScalar(task.goal))")
      lines.append("      workspace: \(task.workspace)")
      lines.append("      capabilities:")
      lines.append("        - agent:model")
      if let timeout = task.timeoutSeconds, timeout > 0 {
        lines.append("      timeoutSeconds: \(timeout)")
      }
      if let next = task.next {
        lines.append("      next: \(yamlScalar(next))")
      }
    }

    if !plan.gates.isEmpty {
      lines.append("  gates:")
      for gate in plan.gates {
        lines.append("    - name: \(gate.name)")
        lines.append("      evaluator: automated")
        lines.append("      automated:")
        lines.append("        check: \(gate.check)")
        if !gate.params.isEmpty {
          lines.append("        params:")
          for key in gate.params.keys.sorted() {
            lines.append("          \(key): \(yamlScalar(gate.params[key] ?? ""))")
          }
        }
        if let repasses = gate.maxRepasses, repasses > 0 {
          lines.append("      maxRepasses: \(repasses)")
        }
        lines.append("      branches:")
        for branch in gate.branches {
          lines.append("        \(branch.outcome): \(yamlScalar(branch.target))")
        }
      }
    }

    return lines.joined(separator: "\n") + "\n"
  }

  /// Quote anything YAML would otherwise reinterpret — `@abort` is a plain-scalar
  /// error, `yes`/`no` become booleans, and a colon starts a mapping.
  static func yamlScalar(_ raw: String) -> String {
    let needsQuoting =
      raw.isEmpty || raw.first == "@" || raw.first == "*" || raw.first == "&"
      || raw.first == " " || raw.last == " " || raw.contains(": ") || raw.contains(" #")
      || raw.hasSuffix(":") || raw.contains("\n")
      || ["yes", "no", "true", "false", "null", "~", "on", "off"].contains(raw.lowercased())
    guard needsQuoting else { return raw }
    let escaped =
      raw
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: " ")
    return "\"\(escaped)\""
  }
}

extension LoopGraphScope {
  /// A human label for the emitted workflow, since a graph carries no title of its own.
  var displayName: String {
    switch self {
    case .global: return "Global"
    case .project(let ref): return ref.name
    }
  }
}
