import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The edge drop editor from docs/06-ux-terminals.md#creating-edges: kind, condition,
/// and payload transform, picked once at creation.
///
/// Kinds `graphcoded` doesn't execute yet are still selectable — the graph is a design
/// record as much as a runtime, and a `.message` edge you can draw but graphcode hasn't
/// learned to deliver is more honest than a picker that pretends the vocabulary is
/// smaller than it is. The inline note is what keeps that from being a silent no-op.
struct EdgeSpecForm: View {
  @Binding var pending: ProjectFeature.PendingEdge
  let fromTitle: String
  let toTitle: String
  let onCancel: () -> Void
  let onCreate: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Text("New Edge").font(.headline)
      Text("\(fromTitle) → \(toTitle)")
        .font(.caption)
        .foregroundStyle(.secondary)

      Form {
        Picker("Kind", selection: $pending.spec.kind) {
          ForEach(EdgeKind.allCases, id: \.self) { kind in
            Text(kind.displayName).tag(kind)
          }
        }
        .pickerStyle(.segmented)

        if !pending.spec.kind.isExecutable {
          Label(
            "Stored and drawn, but not delivered yet — see the Phase 6 roadmap.",
            systemImage: "info.circle"
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }

        Picker("Fires", selection: $pending.spec.condition) {
          ForEach(EdgeCondition.allCases, id: \.self) { condition in
            Text(condition.displayName).tag(condition)
          }
        }
        .disabled(!pending.spec.kind.isExecutable)

        Picker("Hands off", selection: $pending.transformMode) {
          ForEach(ProjectFeature.TransformMode.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }

        switch pending.transformMode {
        case .none:
          EmptyView()
        case .template:
          TextField("What carries across", text: $pending.transformText)
        case .script:
          TextField("shell command", text: $pending.transformText)
            .font(.system(.body, design: .monospaced))
        }

        if pending.spec.kind.isExecutable {
          Divider()

          // The cycle guard from docs/02-graph-of-loops.md, surfaced as one switch
          // because it does one thing: let this edge run the loop again, bounded. There
          // is deliberately no way to enable repetition without a bound.
          Toggle("Loop back to an earlier step", isOn: $pending.loops)

          if pending.loops {
            Stepper(
              "At most \(pending.maxIterations) passes",
              value: $pending.maxIterations, in: 1...50)
            TextField("stop early when this exits 0 (optional)", text: $pending.untilCommand)
              .font(.system(.body, design: .monospaced))
            Text("Each pass resets the loops between here and the target.")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }

      HStack {
        Button("Cancel", action: onCancel)
        Spacer()
        Button("Create", action: onCreate)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 380)
  }
}
