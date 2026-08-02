import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The 76pt strip along the window's bottom: what has happened lately, newest first.
///
/// The graph answers "what is true now" and answers it well. It has never answered "what
/// happened while I was in a terminal" — a loop that ran, handed off, and finished in the
/// twenty minutes you were reading code leaves a canvas that looks exactly like the one
/// you left, only with different words on it.
///
/// Behind `GraphcodeSettings.showsActivityStrip`, off by default, because it is derived
/// (see `ActivityFeed`) and therefore starts empty at launch and knows only what it has
/// seen since. A permanently thin panel teaches people to stop looking at the panels
/// beside it — the same argument that keeps the cost rollup out of the sidebar.
struct ActivityStripView: View {
  @Bindable var store: StoreOf<AppFeature>
  let now: Date

  private var events: [ActivityEvent] { store.state.activityEvents(now: now) }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      header
      if events.isEmpty {
        Text("Nothing yet — passes, hand-offs and state changes land here as they happen.")
          .font(.system(size: 11.5))
          .foregroundStyle(.white.opacity(0.35))
      } else {
        chips
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .frame(height: 76, alignment: .top)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.activityStrip)
    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("ACTIVITY")
        .font(.system(size: 10.5, weight: .bold))
        .tracking(0.6)
        .foregroundStyle(.white.opacity(0.4))
      Text(ActivityFeed.summary(events))
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.4))
      Spacer(minLength: 8)
      Toggle(
        "Only attention",
        isOn: Binding(
          get: { store.activityFilterIsAttention },
          set: { _ in store.send(.activityFilterToggled) })
      )
      .toggleStyle(.checkbox)
      .font(.system(size: 11))
      .foregroundStyle(.white.opacity(0.5))
    }
  }

  /// Newest first, left to right, and scrolling horizontally rather than wrapping: the
  /// strip is one row tall by design, and a growing panel at the bottom of the window
  /// would push the canvas around every time a loop did anything.
  private var chips: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        ForEach(events) { event in
          chip(event)
        }
      }
    }
    .scrollIndicators(.never)
  }

  private func chip(_ event: ActivityEvent) -> some View {
    HStack(spacing: 6) {
      Text(event.timestamp)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.45))
      Text(event.text)
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.8))
    }
    .lineLimit(1)
    .fixedSize()
    .padding(.vertical, 5)
    .padding(.horizontal, 10)
    .background(
      event.isAttention ? Color.orange.opacity(0.1) : .white.opacity(0.04),
      in: RoundedRectangle(cornerRadius: 7)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(
          event.isAttention ? Color.orange.opacity(0.24) : .white.opacity(0.06), lineWidth: 1)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      store.send(.projects(.element(id: event.projectPath, action: .nodeTapped(event.nodeID))))
    }
  }
}
