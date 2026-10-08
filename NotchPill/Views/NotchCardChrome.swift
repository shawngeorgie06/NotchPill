import SwiftUI

/// A shared leading edge for utility cards; controls stay in the trailing slot.
struct NotchCardHeading: View {
    let title: String
    let symbol: String
    var count: Int? = nil
    var icon: NSImage? = nil
    var asset: String? = nil
    var scale: CGFloat = 1
    var textScale: CGFloat = 1

    var body: some View {
        HStack(spacing: NotchSpace.base * scale) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else if let asset {
                    Image(asset).resizable().scaledToFit()
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: NotchType.body * textScale, weight: .medium))
                }
            }
            .frame(width: NotchSpace.mark * scale, height: NotchSpace.mark * scale)
            .frame(width: NotchSpace.well * scale, height: NotchSpace.well * scale)
            .background(.white.opacity(NotchOpacity.wellFill),
                        in: RoundedRectangle(cornerRadius: NotchRadius.well * scale, style: .continuous))
            .accessibilityHidden(true)
            Text(title)
                .font(.system(size: NotchType.title * textScale, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let count {
                Text(count, format: .number)
                    .font(.system(size: NotchType.caption * textScale, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    .fixedSize()
            }
        }
        .foregroundStyle(.white.opacity(NotchOpacity.primary))
        .frame(minHeight: 28 * scale)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct NotchCardPicker: View {
    let items: [NotchDeckPickerItem]
    let selectedKind: String?
    var scale: CGFloat = 1
    var textScale: CGFloat = 1
    var reduceMotion: Bool = false
    let onSelect: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: NotchSpace.base * scale) {
            HStack(spacing: NotchSpace.snug * scale) {
                NotchCardHeading(title: "All Cards", symbol: "square.grid.2x2",
                                 count: items.count, scale: scale, textScale: textScale)
                Spacer(minLength: NotchSpace.snug * scale)
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: NotchType.body * textScale, weight: .semibold))
                        .frame(width: 28 * scale, height: 28 * scale)
                }
                .buttonStyle(NotchChromeButtonStyle(reduceMotion: reduceMotion))
                .accessibilityLabel("Back to selected card")
                .help("Back to selected card")
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: NotchSpace.base * scale) {
                        ForEach(0..<((items.count + 1) / 2), id: \.self) { row in
                            HStack(spacing: NotchSpace.base * scale) {
                                ForEach(Array(items.dropFirst(row * 2).prefix(2))) { item in
                                    Button { onSelect(item.kind) } label: {
                                        HStack(spacing: NotchSpace.base * scale) {
                                            Image(systemName: item.kind == selectedKind ? "checkmark" : item.symbolName)
                                                .font(.system(size: NotchType.body * textScale, weight: .medium))
                                                .frame(width: 18 * scale)
                                                .accessibilityHidden(true)
                                            Text(item.title)
                                                .font(.system(size: NotchType.body * textScale, weight: .medium))
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(.horizontal, NotchSpace.base * scale)
                                        .frame(maxWidth: .infinity, minHeight: 44 * scale)
                                        .contentShape(RoundedRectangle(cornerRadius: NotchRadius.card * scale, style: .continuous))
                                    }
                                    .buttonStyle(NotchChromeButtonStyle(selected: item.kind == selectedKind,
                                                                       reduceMotion: reduceMotion))
                                    .id(item.kind)
                                    .accessibilityLabel("Show \(item.title)")
                                    .accessibilityAddTraits(item.kind == selectedKind ? .isSelected : [])
                                }
                                if row * 2 + 1 >= items.count {
                                    Color.clear.frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                    .padding(1)
                }
                .scrollIndicators(.visible)
                .scrollBounceBehavior(.basedOnSize)
                .onAppear { if let selectedKind { proxy.scrollTo(selectedKind, anchor: .center) } }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, NotchSpace.section * scale)
        .padding(.vertical, NotchSpace.base * scale)
        .onExitCommand(perform: onClose)
    }
}

struct NotchChromeButtonStyle: ButtonStyle {
    var selected = false
    var reduceMotion = false

    func makeBody(configuration: Configuration) -> some View {
        ChromeButton(configuration: configuration, selected: selected, reduceMotion: reduceMotion)
    }

    private struct ChromeButton: View {
        let configuration: Configuration
        let selected: Bool
        let reduceMotion: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(.white.opacity(selected || hovered ? 0.96 : NotchOpacity.secondary))
                .background(.white.opacity(configuration.isPressed ? 0.18 : selected ? 0.12 : hovered ? 0.09 : 0.045),
                            in: RoundedRectangle(cornerRadius: NotchRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: NotchRadius.card, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.24 : hovered ? 0.12 : 0.04), lineWidth: 1))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .onHover { hovered = $0 }
                .animation(NotchMotion.paint(reduceMotion: reduceMotion), value: hovered)
                .animation(NotchMotion.paint(reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }
}

/// A compact empty state that fits the same canvas as populated cards.
struct NotchEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var actionTitle: String? = nil
    var action: () -> Void = {}
    var scale: CGFloat = 1
    var textScale: CGFloat = 1
    var reduceMotion = false

    var body: some View {
        // Search takes a row out of the clipboard canvas. Yield the decorative
        // symbol before compressing the explanation or its return action.
        ViewThatFits(in: .vertical) {
            content(showSymbol: true)
            content(showSymbol: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(showSymbol: Bool) -> some View {
        VStack(spacing: NotchSpace.snug * scale) {
            if showSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 20 * textScale, weight: .regular))
                    .foregroundStyle(.white.opacity(0.4))
                    .accessibilityHidden(true)
                    .padding(.bottom, NotchSpace.snug * scale)
            }
            VStack(spacing: NotchSpace.snug * scale) {
                Text(title)
                    .font(.system(size: NotchType.body * textScale, weight: .semibold))
                    .foregroundStyle(.white.opacity(NotchOpacity.primary))
                Text(detail)
                    .font(.system(size: NotchType.caption * textScale))
                    .foregroundStyle(.white.opacity(NotchOpacity.secondary))
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: NotchType.caption * textScale, weight: .medium))
                        .padding(.horizontal, NotchSpace.roomy * scale)
                        .padding(.vertical, NotchSpace.snug * scale)
                }
                .buttonStyle(NotchChromeButtonStyle(reduceMotion: reduceMotion))
            }
        }
        .padding(NotchSpace.base * scale)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }
}
