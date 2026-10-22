import SwiftUI

/// One option in a card's menu; `groupTitle` starts a new section above it.
struct CardOption: Identifiable {
    let id: String
    let label: String
    var groupTitle: String? = nil
}

/// A card for one control (Mode, Fan, Sleep, Direction) showing its current value; a
/// click opens its options in a popover.
struct ControlCard: View {
    let title: String
    let value: String
    let icon: String
    let status: String
    let active: Bool
    let enabled: Bool
    let options: [CardOption]
    let selected: String?
    var selectedIDs: Set<String> = []
    var explanation: String? = nil
    let select: (String) -> Void
    @State private var expanded = false
    @State private var hovered = false
    private var accent: Color { active ? .cyan : .white.opacity(0.5) }

    var body: some View {
        Button { expanded = true } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: icon).font(.system(size: 18, weight: .light)).foregroundStyle(accent)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.white.opacity(0.45))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                    Text(value).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.85)
                }
                if !status.isEmpty {
                    Text(status).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading).frame(height: 92)
            .modifier(ControlSurface(accent: active ? .cyan : .clear, interactive: enabled))
            .brightness(hovered && enabled ? 0.035 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .accessibilityLabel([title, value, status].filter { !$0.isEmpty }.joined(separator: ", "))
        .help(explanation ?? (enabled ? "Alterar \(title.lowercased())" : "\(title): \(status)"))
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            ControlOptions(title: title, options: options, selected: selected,
                           selectedIDs: selectedIDs, explanation: explanation, enabled: enabled) { id in
                expanded = false
                select(id)
            }
        }
    }
}

/// The list of options shown in a card's popover.
struct ControlOptions: View {
    let title: String
    let options: [CardOption]
    let selected: String?
    let selectedIDs: Set<String>
    let explanation: String?
    let enabled: Bool
    let select: (String) -> Void
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold)).padding(.bottom, 4)
                if let explanation {
                    Text(explanation).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
                }
                ForEach(options) { option in
                    ControlOptionRow(option: option,
                                     selected: option.id == selected || selectedIDs.contains(option.id),
                                     enabled: enabled) {
                        select(option.id)
                    }
                }
            }
            .padding(16)
            // Measure the real content so the popover hugs it, scrolling only past 460 pt.
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            })
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(width: 280, height: min(460, max(contentHeight, 1)))
        .preferredColorScheme(.dark)
    }
}

/// Measures the options list, so the popover fits its content instead of a guess.
struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One option row, highlighted with a checkmark when it is the current value.
struct ControlOptionRow: View {
    let option: CardOption
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let group = option.groupTitle {
                Text(group).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary).padding(.top, 6)
            }
            Button(action: action) {
                HStack(spacing: 10) {
                    Text(option.label).font(.system(size: 12))
                    Spacer()
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        .opacity(selected ? 1 : 0)
                }
                .foregroundStyle(selected ? Color.cyan : Color.white)
                .padding(10).frame(maxWidth: .infinity)
                .background(selected ? Color.cyan.opacity(0.12) : Color.white.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!enabled)
            .accessibilityLabel(option.label + (selected ? ", selecionado" : ""))
        }
    }
}
