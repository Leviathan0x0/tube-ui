import SwiftUI

// Shared building blocks for the library pages. LibraryShell owns the shell;
// each Library*PageView file owns one section page.

/// Client-side All / Videos / Shorts chip filter, shared by the history and
/// playlist pages.
enum TubeKindFilter: Int, CaseIterable, Identifiable, Sendable {
    case all = 0
    case videos = 1
    case shorts = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .videos: "Videos"
        case .shorts: "Shorts"
        }
    }

    func matches(_ video: YTVideo) -> Bool {
        switch self {
        case .all: true
        case .videos: !video.isShort
        case .shorts: video.isShort
        }
    }
}

/// Capsule chip row matching the home chip bar visuals.
struct TubeKindChips: View {
    var selection: TubeKindFilter
    var onSelect: (TubeKindFilter) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(TubeKindFilter.allCases) { option in
                let selected = option == selection
                Button {
                    onSelect(option)
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(selected ? TubeColor.chipSelected : TubeColor.chip, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                .hoverLift(scale: 1.03, shadow: 0)
                .focusEffectDisabled()
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// The `…` row control used by history / playlist rows.
struct RowKebab<Content: View>: View {
    @ViewBuilder var menu: () -> Content

    var body: some View {
        Menu {
            menu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More options")
    }
}

/// A video row with the roomier 168px thumbnail the history and playlist pages use.
/// Callers wrap it in a Button and add a RowKebab beside it.
struct WideVideoRow: View {
    var video: YTVideo

    var body: some View {
        HStack(spacing: 14) {
            Color.primary.opacity(0.06)
                .overlay {
                    TubePicture(url: video.thumbnail)
                }
                .overlay(alignment: .bottomTrailing) {
                    if let length = video.length, !length.isEmpty {
                        DurationBadge(text: length)
                    }
                }
                .frame(width: 168, height: 94)
                .clipShape(RoundedRectangle(cornerRadius: TubeMetrics.media, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !video.subtitle.isEmpty {
                    Text(video.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct LibraryPageHeader: View {
    var title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle.weight(.bold))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Staggered entrance delay, capped so long lists never lag behind.
func tubeStagger(_ index: Int) -> Double {
    min(Double(index % 12) * 0.03, 0.3)
}

private func consentCopy(_ section: LibrarySection) -> String {
    switch section {
    case .home:
        "YouTube won't share your home feed until you allow account access."
    case .history:
        "YouTube won't share watch history until you allow account access."
    case .shorts:
        "YouTube won't share Shorts until you allow account access."
    default:
        "YouTube needs permission to share this."
    }
}

/// Section icon. Every section uses an SF Symbol at the same point size inside
/// the same square, so sidebar rows and empty states line up.
func sectionStateIcon(_ section: LibrarySection, size: CGFloat, weight: Font.Weight = .regular, scale: CGFloat = 0.72) -> some View {
    Image(systemName: section.sfSymbol)
        .resizable()
        .scaledToFit()
        .font(.system(size: size * scale, weight: weight))
        .frame(width: size * scale, height: size * scale)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
}

/// Centered empty / error / consent illustration. The icon sits above the title
/// in one column so every section page lines up the same way.
struct TubeEmptyState<Actions: View>: View {
    var section: LibrarySection
    var title: String
    var message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            sectionStateIcon(section, size: 64)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            actions()
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity, alignment: .center)
    }
}

/// Inline note for a kind filter (Videos/Shorts) that matches nothing while the
/// unfiltered list still has items — keeps the chips and page chrome visible
/// instead of swapping in a full-page empty state.
func tubeKindEmptyNote(_ filter: TubeKindFilter) -> some View {
    VStack(spacing: 4) {
        Text("No \(filter.title) here")
        Text("Nothing matches this filter.")
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 48)
}

/// The shared consent / note / empty states for a section. Callers show this
/// instead of their content when the section's items are empty.
@MainActor
func libraryStateView(_ section: LibrarySection, onRetry: @escaping () -> Void) -> some View {
    libraryStateCore(section, onRetry: onRetry)
}

@MainActor
@ViewBuilder
private func libraryStateCore(_ section: LibrarySection, onRetry: @escaping () -> Void) -> some View {
    let model = TubeModel.shared
    if let note = model.library.notes[section] {
        TubeEmptyState(section: section, title: section.title, message: note) {
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
                .tint(TubeColor.red)
        }
    } else if model.library.consent.contains(section) {
        TubeEmptyState(section: section, title: section.title, message: consentCopy(section)) {
            Button(model.isAuthorizing ? "Waiting for Google…" : "Allow access") {
                model.signIn()
            }
            .buttonStyle(.borderedProminent)
            .tint(TubeColor.red)
            .disabled(model.isAuthorizing)
        }
    } else {
        TubeEmptyState(section: section, title: section.emptyCopy, message: section.subtitle) {
            EmptyView()
        }
    }
}
