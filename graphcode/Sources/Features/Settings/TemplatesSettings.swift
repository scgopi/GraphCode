import GraphcodeKit
import SwiftUI

/// The template library, as Settings can see it — the **Manage…** destination the
/// ⌘T picker's footer points at (PROMPT_TEMPLATES.md § Picker).
///
/// Both locations are listed, not just home: a project's committed templates are
/// what a team actually shares, and a list that hid them would make "project
/// templates are read too" invisible in the one place templates are managed.
///
/// Each row opens `TemplateEditorView`, which is where § Follow vs snapshot's
/// load-bearing line lives — "3 scheduled loops use this — they'll pick up changes
/// on their next run." The reach of an edit has to be visible *before* it is saved,
/// because a committed edit to a project template changes what runs on a teammate's
/// machine.
struct TemplatesSettingsSection: View {
  @State private var templates: [PromptTemplate] = []
  @State private var usage: [UUID: TemplateUsage] = [:]
  @State private var pendingDeletion: PromptTemplate?
  @State private var editing: PromptTemplate?

  var body: some View {
    Section {
      if templates.isEmpty {
        Text(
          "No templates yet. Save one from the New loop dialog (⌘T), or right-click a "
            + "loop that worked and choose Save as Template…."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      } else {
        ForEach(templates) { template in
          row(template)
        }
      }
    } header: {
      Text("Templates")
    } footer: {
      Text(
        "One template is one markdown file — editable here or in any editor, shareable "
          + "by committing it into a project's .graphcode/templates. Timed and composite "
          + "loops that started from one follow it and pick up edits on their next run; a "
          + "loop can be detached from its card. Each project reads its own committed "
          + "templates first, so a committed edit changes what runs on a teammate's machine."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .onAppear(perform: reload)
    .sheet(item: $editing) { template in
      TemplateEditorView(
        template: template,
        usage: usage[template.id] ?? TemplateUsage(),
        onSave: { edited in
          _ = try? TemplateStorage.shared.update(edited, replacing: template)
          editing = nil
          reload()
        },
        onCancel: { editing = nil })
    }
    // A template is a file, and a project one is a file in somebody's checkout. The
    // list is the only place they can be deleted, so the click asks first.
    .confirmationDialog(
      "Delete “\(pendingDeletion?.name ?? "")”?",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } })
    ) {
      Button("Delete template", role: .destructive) {
        if let template = pendingDeletion { try? TemplateStorage.shared.delete(template) }
        pendingDeletion = nil
        reload()
      }
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
    } message: {
      Text(deletionWarning)
    }
  }

  private func row(_ template: PromptTemplate) -> some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 2)
        .fill((template.shape ?? .sketch).accent)
        .frame(width: 9, height: 9)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          Text(template.name).font(.callout)
          if template.origin.isProject {
            Text("in project")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
          }
        }
        Text(subtitle(template))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Button("Edit") { editing = template }
        .buttonStyle(.link)
        .font(.caption)
      Button("Reveal") { reveal(template) }
        .buttonStyle(.link)
        .font(.caption)
      Button("Delete", role: .destructive) { pendingDeletion = template }
        .buttonStyle(.link)
        .font(.caption)
    }
    .padding(.vertical, 2)
  }

  /// Deleting a followed template does not stop the loops following it — they keep
  /// their last-known snapshot and warn — so the dialog says so rather than letting
  /// someone guess that deleting is a way to stop a nightly run.
  private var deletionWarning: String {
    guard let template = pendingDeletion else { return "" }
    var text = "This removes \(TemplateSavePath.display(of: template))."
    let following = usage[template.id]?.following ?? 0
    if following > 0 {
      text +=
        following == 1
        ? " 1 loop follows it; it will keep running on the brief it last read, and say so on its card."
        : " \(following) loops follow it; they'll keep running on the brief they last read, and say so on their cards."
    }
    return text
  }

  private func subtitle(_ template: PromptTemplate) -> String {
    var parts: [String] = []
    switch template.shape {
    case .sketch, nil: parts.append("Main")
    case .goalBased: parts.append("Goal")
    case .timeBased:
      let cadence = template.settings?.cadence.map { $0.lowercased() } ?? ""
      parts.append(cadence.isEmpty ? "Timed" : "Timed · \(cadence)")
    case .turnBased: parts.append("Turn")
    case .composite: parts.append("Composite")
    }
    if template.useCount > 0 { parts.append("used \(template.useCount)×") }
    if let following = usage[template.id]?.followingLine { parts.append(following) }
    parts.append(template.summaryLine)
    return parts.joined(separator: " — ")
  }

  /// The file this row stands for — which is not always in the home folder, so the
  /// origin decides rather than the assumption that everything listed here is home's.
  private func reveal(_ template: PromptTemplate) {
    let storage = TemplateStorage.shared
    let directory: URL
    switch template.origin {
    case .home: directory = storage.homeDirectory
    case .project(let path): directory = storage.projectDirectory(path)
    }
    NSWorkspace.shared.activateFileViewerSelecting([
      directory.appendingPathComponent(template.fileName)
    ])
  }

  /// Home's templates plus every known project's, and the loop counts behind them.
  ///
  /// Settings has no project of its own, so "known" is the recent-projects list —
  /// the same folders the sidebar offers. Read straight off disk rather than through
  /// a store: these are small local JSON files, and wiring the whole app's state into
  /// the Settings window to count integers would be the larger change.
  private func reload() {
    let persistence = ProjectPersistence(baseDirectory: SupportDirectory.url)
    let projects = persistence.loadRecentProjects()
    let storage = TemplateStorage.shared

    var seen = Set<TemplateOrigin>()
    var found: [PromptTemplate] = []
    for path in projects.map(\.path) where seen.insert(.project(path)).inserted {
      found += storage.load(projectPath: path).filter(\.origin.isProject)
    }
    found += storage.load(projectPath: nil)

    let graphs = projects.compactMap { persistence.loadGraph(path: $0.path) }
    templates = TemplateLibraryClient.overlayUseCounts(found)
    usage = Dictionary(
      uniqueKeysWithValues: templates.map { ($0.id, TemplateUsage.of($0.id, in: graphs)) })
  }
}

/// The template editor — the one screen where a template's own text can be changed,
/// and where the reach of that change is stated before it is saved.
///
/// PROMPT_TEMPLATES.md § Follow vs snapshot calls the usage line load-bearing rather
/// than decorative, and this is why: editing a project template that three nightly
/// loops follow changes what runs on every machine that has the file, including a
/// teammate's after a `git pull`. The line is placed above Save, not below the title,
/// so it is read on the way to the button.
struct TemplateEditorView: View {
  let template: PromptTemplate
  let usage: TemplateUsage
  let onSave: (PromptTemplate) -> Void
  let onCancel: () -> Void

  @State private var name: String
  @State private var brief: String
  @State private var shape: LoopType?
  @State private var doneCheck: String
  @State private var cadence: String
  @State private var metric: String
  @State private var branch: String
  @State private var pausesBeforeWritesOnly: Bool

  init(
    template: PromptTemplate, usage: TemplateUsage,
    onSave: @escaping (PromptTemplate) -> Void, onCancel: @escaping () -> Void
  ) {
    self.template = template
    self.usage = usage
    self.onSave = onSave
    self.onCancel = onCancel
    _name = State(initialValue: template.name)
    _brief = State(initialValue: template.body)
    _shape = State(initialValue: template.shape)
    _doneCheck = State(initialValue: template.settings?.doneCheck ?? "")
    _cadence = State(initialValue: template.settings?.cadence ?? "")
    _metric = State(initialValue: template.settings?.metric ?? "")
    _branch = State(initialValue: template.settings?.branch ?? "")
    _pausesBeforeWritesOnly = State(
      initialValue: template.settings?.pausesBeforeWritesOnly ?? false)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Form {
        Section {
          TextField("Name", text: $name)
          Picker("Shape", selection: $shape) {
            Text("Main").tag(LoopType?.none)
            Text("Goal").tag(LoopType?.some(.goalBased))
            Text("Timed").tag(LoopType?.some(.timeBased))
            Text("Turn").tag(LoopType?.some(.turnBased))
            Text("Composite").tag(LoopType?.some(.composite))
          }
        } footer: {
          Text("The type the brief assumes. Main carries the text alone.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        Section {
          TextEditor(text: $brief)
            .font(.system(size: 12))
            .frame(minHeight: 120)
        } header: {
          Text("Brief")
        } footer: {
          tokenFooter
        }

        shapeSettings

        Section {
          TextField("Branch", text: $branch, prompt: Text("optional — a new branch to cut"))
        } footer: {
          Text("A worktree the loop works in. Left blank, it runs in the checkout.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      Divider()
      footer
    }
    .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 640)
  }

  @ViewBuilder
  private var shapeSettings: some View {
    switch shape {
    case .goalBased:
      Section {
        TextField("Done check", text: $doneCheck, prompt: Text("make test"))
          .font(.system(size: 12, design: .monospaced))
        TextField("Measured by", text: $metric, prompt: Text("./scripts/score.sh"))
          .font(.system(size: 12, design: .monospaced))
      } footer: {
        Text("Runs periodically while the loop works. Exit 0 means done.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    case .timeBased:
      Section {
        TextField("Cadence", text: $cadence, prompt: Text("1h · daily · 45m"))
      } footer: {
        Text(
          "Written into the loop's own /loop directive. Loops following this template "
            + "pick a changed cadence up on their next run."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
    case .turnBased:
      Section {
        Toggle("Pause only before it writes files", isOn: $pausesBeforeWritesOnly)
      }
    case .composite, .sketch, .none:
      EmptyView()
    }
  }

  @ViewBuilder
  private var tokenFooter: some View {
    let tokens = PromptTemplate.tokens(in: brief)
    if tokens.isEmpty {
      Text("Write {like_this} to leave a hole for whoever uses the template to fill.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    } else {
      Text(
        "Fills in at use time: " + tokens.map { "{\($0)}" }.joined(separator: " ")
          + ". Unfilled tokens block Start."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      // The load-bearing half of follow-vs-snapshot, above the button that commits
      // the edit — see this type's own doc comment.
      if let line = usage.followingLine {
        Label {
          Text(line).font(.caption)
        } icon: {
          Circle().fill(Color(red: 0.039, green: 0.518, blue: 1.0)).frame(width: 5, height: 5)
        }
        .foregroundStyle(.primary)
      }
      if let line = usage.snapshotLine {
        Text(line).font(.caption2).foregroundStyle(.secondary)
      }
      if template.origin.isProject {
        Text(
          "This template lives in the project. Committing an edit changes what runs on "
            + "everyone else's machine too."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
      HStack {
        Text(TemplateSavePath.display(of: template))
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 12)
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save") { onSave(edited) }
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(16)
  }

  /// The edited template. `id` is restored by `TemplateStorage.update`, which is what
  /// keeps every following loop attached across the edit.
  private var edited: PromptTemplate {
    func trimmed(_ value: String) -> String? {
      let text = value.trimmingCharacters(in: .whitespaces)
      return text.isEmpty ? nil : text
    }
    var settings = TemplateSettings()
    settings.backend = template.settings?.backend
    settings.graphJSON = template.settings?.graphJSON
    settings.branch = trimmed(branch)
    if shape == .goalBased {
      settings.doneCheck = trimmed(doneCheck)
      settings.metric = trimmed(metric)
    }
    if shape == .timeBased { settings.cadence = trimmed(cadence) }
    if shape == .turnBased { settings.pausesBeforeWritesOnly = pausesBeforeWritesOnly }
    return PromptTemplate(
      id: template.id,
      name: name.trimmingCharacters(in: .whitespaces),
      body: brief.trimmingCharacters(in: .whitespacesAndNewlines),
      shape: shape,
      settings: settings.isEmpty ? nil : settings,
      origin: template.origin)
  }
}
