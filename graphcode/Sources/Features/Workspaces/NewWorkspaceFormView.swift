import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// Name a workspace, and GraphCode opens it in a second window of its own.
///
/// The sheet shows the directory the name resolves to, because that directory *is* the
/// workspace — it is where its graphs live, what a `GRAPHCODE_SUPPORT_DIR` on the CLI
/// would point at, and what someone deleting a workspace later has to remove.
///
/// **Why a picture rather than a paragraph.** The explainer this replaced was three lines
/// of caption above a single text field — the largest thing in the dialog, read once, in
/// the way forever. What someone actually needs to know before pressing Create is what
/// they are about to get: another window, its own daemon, an empty sidebar. The diagram
/// says all three at a glance and stops being read the moment it stops being news.
struct NewWorkspaceFormView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("New Workspace").font(.headline)

      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 6) {
          TextField("", text: name, prompt: Text("Client Work"))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 15))
            .autocorrectionDisabled()
            .onSubmit { if canCreate { store.send(.workspaces(.createConfirmed)) } }

          detail

          VStack(alignment: .leading, spacing: 5) {
            bullet("Its own projects and loops", isPresent: true)
            bullet("Its own background daemon", isPresent: true)
            bullet("Nothing shared with \(store.workspaces.current.name)", isPresent: false)
          }
          .padding(.top, 6)
        }

        WorkspacePreview(name: previewName)
      }

      HStack {
        Spacer()
        Button("Cancel") { store.send(.workspaces(.createCancelled)) }
          .keyboardShortcut(.cancelAction)
        Button("Create & Open") { store.send(.workspaces(.createConfirmed)) }
          .keyboardShortcut(.defaultAction)
          .disabled(!canCreate)
      }
    }
    .padding(24)
    .frame(width: 460)
  }

  /// One line, and it is the *path* whenever there is one to show: a name that is still
  /// being typed is not yet a mistake, so an empty field says nothing at all rather than
  /// scolding.
  @ViewBuilder
  private var detail: some View {
    Group {
      if let problem = store.workspaces.problem {
        Text(problem).foregroundStyle(.red)
      } else if !directoryPath.isEmpty {
        Text(directoryPath).foregroundStyle(.secondary)
      } else {
        Text(" ")
      }
    }
    .font(.caption)
    .lineLimit(1)
    .truncationMode(.middle)
  }

  private func bullet(_ text: String, isPresent: Bool) -> some View {
    HStack(spacing: 7) {
      Image(systemName: isPresent ? "plus" : "minus")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.white.opacity(isPresent ? 0.5 : 0.35))
        .frame(width: 12)
      Text(text)
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(isPresent ? 0.6 : 0.45))
    }
  }

  private var name: Binding<String> {
    Binding(
      get: { store.workspaces.draftName },
      set: { store.send(.workspaces(.draftNameChanged($0))) })
  }

  private var canCreate: Bool {
    store.workspaces.problem == nil && !store.workspaces.draftName.isEmpty
  }

  /// The typed name until it resolves, so the window in the diagram is titled with what
  /// is being typed rather than blinking between states.
  private var previewName: String {
    let typed = store.workspaces.draftName.trimmingCharacters(in: .whitespaces)
    return typed.isEmpty ? "Client Work" : typed
  }

  private var directoryPath: String {
    guard case .success(let workspace) = Workspace.validate(name: store.workspaces.draftName)
    else { return "" }
    return (workspace.url.path as NSString).abbreviatingWithTildeInPath
  }
}

/// The second window, drawn small: title bar, sidebar, and the empty canvas it opens on.
///
/// Deliberately not a screenshot and deliberately not accurate — it is a diagram of "one
/// more window, starting empty", and the one detail that has to be right is the name in
/// its title bar, because that is the thing being decided.
private struct WorkspacePreview: View {
  let name: String

  var body: some View {
    VStack(spacing: 7) {
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 5)
          .fill(.white.opacity(0.03))
          .strokeBorder(.white.opacity(0.1), lineWidth: 1)
          .frame(width: 108, height: 74)
          .offset(x: 0, y: 10)

        VStack(spacing: 0) {
          HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
              Circle().fill(.white.opacity(0.22)).frame(width: 5, height: 5)
            }
            Spacer(minLength: 4)
            Text(name)
              .font(.system(size: 7))
              .foregroundStyle(.white.opacity(0.55))
              .lineLimit(1)
              .truncationMode(.tail)
          }
          .padding(.horizontal, 5)
          .frame(height: 15)
          .background(.white.opacity(0.05))

          Divider().overlay(.white.opacity(0.09))

          HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
              RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.13)).frame(height: 3)
              RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.1))
                .frame(width: 16, height: 3)
              Spacer(minLength: 0)
            }
            .padding(5)
            .frame(width: 32)

            Divider().overlay(.white.opacity(0.07))

            Text("empty")
              .font(.system(size: 7))
              .foregroundStyle(.white.opacity(0.3))
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .frame(width: 118, height: 84)
        .background(Color(white: 0.165), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
          RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 9, x: -6, y: 5)
        .offset(x: 26, y: 0)
      }
      .frame(width: 150, height: 96)

      Text("A second window, starting empty")
        .font(.system(size: 10))
        .foregroundStyle(.white.opacity(0.4))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(width: 150)
  }
}
