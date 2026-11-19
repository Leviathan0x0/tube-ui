import SwiftUI

struct CommentsPanel: View {
    var scrolling: Bool
    var showsClose: Bool
    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            orderChips
            if let actionError = model.actionError {
                TubeNotice(message: actionError)
            }
            composer
            if model.commentsLoading && model.comments.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let note = model.commentsNote, model.comments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                    if !note.localizedCaseInsensitiveContains("turned off") {
                        Button("Try again") {
                            model.reloadComments()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            if scrolling {
                ScrollView(showsIndicators: false) {
                    rows
                }
                .scrollIndicators(.hidden)
            } else {
                rows
            }
        }
        .padding(.horizontal, showsClose ? 16 : 0)
        .padding(.vertical, showsClose ? 16 : 0)
        .frame(maxWidth: .infinity, maxHeight: scrolling ? .infinity : nil, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Comments")
                .font(.headline)
            if let count = model.commentCount, !count.isEmpty {
                Text(count)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if showsClose {
                Button {
                    model.commentsOpen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close comments")
            }
        }
    }

    /// YouTube-style chip bar; shown only when a comment list is actually loaded.
    @ViewBuilder private var orderChips: some View {
        if !model.commentsLoading && !model.comments.isEmpty {
            HStack(spacing: 8) {
                ForEach(CommentOrder.allCases) { order in
                    Button {
                        guard order != model.commentOrder else { return }
                        Task { await model.setCommentOrder(order) }
                    } label: {
                        Text(order.rawValue)
                            .font(.caption.weight(model.commentOrder == order ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(model.commentOrder == order ? 0.12 : 0.05))
                            }
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TubeLineField(
                text: Binding(get: { model.commentDraft }, set: { model.commentDraft = $0 }),
                placeholder: "Add a comment",
                multiline: true
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 36)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
            Button {
                Task { await model.postComment() }
            } label: {
                Text(model.commentPosting ? "Posting…" : "Post")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill((draftIsBlank || model.commentPosting) ? TubeColor.red.opacity(0.45) : TubeColor.red)
                    }
            }
            .buttonStyle(PressScaleStyle())
            .disabled(draftIsBlank || model.commentPosting)
        }
    }

    private var draftIsBlank: Bool {
        model.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(Array(model.comments.enumerated()), id: \.element.id) { index, comment in
                CommentRow(comment: comment, nested: false)
                    .hoverLift(scale: 1.01, shadow: 5)
                    .springIn(delay: Double(min(index, 8)) * 0.04)
            }
            if model.commentContinuation != nil {
                Button(model.commentsLoadingMore ? "Loading…" : "More comments") {
                    Task { await model.loadMoreComments() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.commentsLoadingMore)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommentRow: View {
    var comment: YTComment
    var nested: Bool
    private var model: TubeModel { TubeModel.shared }
    @State private var expanded = false
    @State private var loadingReplies = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                authorButton
                VStack(alignment: .leading, spacing: 6) {
                    Text(comment.author)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(comment.text)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    metaLine
                    if comment.replyCount > 0 {
                        repliesToggle
                    }
                }
            }
            if !nested && expanded {
                ForEach(comment.replies) { reply in
                    CommentRow(comment: reply, nested: true)
                        .padding(.leading, 44)
                        .springIn(delay: 0.02)
                }
            }
        }
    }

    /// Author, time and likes compacted into one caption line.
    private var metaLine: some View {
        HStack(spacing: 6) {
            if let published = comment.published, !published.isEmpty {
                Text(published)
            }
            if let likes = comment.likes, likes != "0" {
                HStack(spacing: 3) {
                    Image(systemName: "hand.thumbsup")
                    Text(likes)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var repliesToggle: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                expanded.toggle()
            }
            guard expanded else { return }
            Task {
                loadingReplies = true
                await model.loadReplies(for: comment.id)
                loadingReplies = false
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(expanded
                    ? "Hide replies"
                    : comment.replyCount == 1 ? "View 1 reply" : "View \(comment.replyCount) replies")
                if loadingReplies {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    @ViewBuilder private var authorButton: some View {
        let avatar = Avatar(url: comment.avatar, name: comment.author, size: nested ? 24 : 32)
        if let channelID = comment.channelID, channelID.hasPrefix("UC") {
            Button {
                model.openChannel(id: channelID, name: comment.author)
            } label: {
                avatar
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(comment.author)
        } else {
            avatar
        }
    }
}
