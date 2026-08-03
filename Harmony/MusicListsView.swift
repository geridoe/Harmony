import SwiftUI

/// Owner-facing Collections index. The parent decides where this page enters
/// the app's navigation; the feature keeps its own editor and detail routes.
struct MusicListsView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @State private var showingCreate = false
    @State private var attemptedInitialLoad = false

    var body: some View {
        List {
            if collectionsErrorMessage != nil {
                Section {
                    CollectionsErrorBanner(message: collectionsErrorMessage!) {
                        Task { await store.refreshOwnerMusicLists() }
                    }
                }
            }

            Section {
                if store.isRefreshingOwnerMusicLists && store.ownerMusicLists.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading your lists…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("music-lists-loading")
                } else if attemptedInitialLoad && store.ownerMusicLists.isEmpty {
                    CollectionsEmptyState(
                        title: "Make your first music list",
                        detail: "Build a ranked countdown, party crate, theme collection, or anything else you want to share.",
                        actionTitle: "Create a list",
                        action: { showingCreate = true }
                    )
                    .accessibilityIdentifier("music-lists-empty")
                } else {
                    ForEach(store.ownerMusicLists) { list in
                        NavigationLink {
                            MusicListDetailView(listID: list.id)
                        } label: {
                            MusicListIndexRow(list: list)
                        }
                        .accessibilityIdentifier("music-list-row-\(list.id.uuidString)")
                    }
                }

                if store.hasMoreOwnerMusicLists {
                    Button {
                        Task { await store.loadMoreOwnerMusicLists() }
                    } label: {
                        if store.isLoadingMoreOwnerMusicLists {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Load more lists").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(store.isLoadingMoreOwnerMusicLists)
                    .accessibilityIdentifier("music-lists-load-more")
                }
            } header: {
                Text("Your collections")
            } footer: {
                Text("Lists are independent of Want to listen, your queue, ratings, and listening history.")
            }
        }
        .navigationTitle("Lists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreate = true
                } label: {
                    Label("Create a list", systemImage: "plus")
                }
                .accessibilityIdentifier("music-lists-create")
            }
        }
        .sheet(isPresented: $showingCreate) {
            NavigationStack {
                MusicListEditorView(list: nil)
            }
            .environmentObject(store)
        }
        .task {
            await store.refreshOwnerMusicLists()
            attemptedInitialLoad = true
        }
        .refreshable {
            await store.refreshOwnerMusicLists()
            attemptedInitialLoad = true
        }
        .accessibilityIdentifier("music-lists-page")
    }

    private var collectionsErrorMessage: String? {
        let message = store.collaborationMessage
        let lower = message.lowercased()
        return lower.contains("could not") && lower.contains("list") ? message : nil
    }
}

private struct MusicListIndexRow: View {
    @EnvironmentObject private var store: HarmonySessionStore
    let list: RemoteMusicList

    private var cachedEntries: [RemoteMusicListEntry] {
        Array(store.musicListDetail(for: list.id).entries.items.prefix(4))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MusicListArtworkMosaic(entries: cachedEntries, size: 72)

            VStack(alignment: .leading, spacing: 5) {
                Text(list.title)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if list.isRanked {
                        Label("Ranked", systemImage: "list.number")
                    }
                    if list.visibility == .privateOnly {
                        Label("Private", systemImage: "lock.fill")
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.indigo)

                if !list.description.isEmpty {
                    Text(list.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !list.tags.isEmpty {
                    Text(list.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(list.updatedAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MusicListDetailView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @Environment(\.dismiss) private var dismiss
    let listID: UUID

    @State private var editingList: RemoteMusicList?
    @State private var commentBody = ""
    @State private var showingDeleteConfirmation = false
    @State private var attemptedLoad = false

    private var detail: MusicListDetailState { store.musicListDetail(for: listID) }
    private var list: RemoteMusicList? { detail.list }

    var body: some View {
        List {
            if detail.isRefreshing && list == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading list…").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("music-list-detail-loading")
            } else if attemptedLoad && list == nil {
                CollectionsEmptyState(
                    title: "List unavailable",
                    detail: "It may be private, deleted, or no longer shared with you.",
                    actionTitle: "Try again",
                    action: { Task { await reload() } }
                )
                .accessibilityIdentifier("music-list-detail-unavailable")
            } else if let list {
                header(list)
                entriesSection(list)
                engagementSection(list)
                commentsSection
            }
        }
        .navigationTitle(list?.title ?? "List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let list, store.isOwnMusicList(list) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Edit list", systemImage: "pencil") { editingList = list }
                        Button("Delete list", systemImage: "trash", role: .destructive) {
                            showingDeleteConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("List options")
                    .accessibilityIdentifier("music-list-options")
                }
            }
        }
        .sheet(item: $editingList, onDismiss: {
            Task { await reload() }
        }) { list in
            NavigationStack {
                MusicListEditorView(list: list)
            }
            .environmentObject(store)
        }
        .confirmationDialog("Delete this list?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete list", role: .destructive) {
                guard let list else { return }
                Task {
                    if await store.deleteMusicList(list) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its entries, likes, comments, and follower activity will no longer be visible.")
        }
        .task { await reload() }
        .refreshable { await reload() }
        .accessibilityIdentifier("music-list-detail-page")
    }

    @ViewBuilder
    private func header(_ list: RemoteMusicList) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                MusicListArtworkMosaic(entries: detail.entries.items, size: 180)
                    .frame(maxWidth: .infinity)

                Text(list.title)
                    .font(.title2.bold())
                Text("by \(list.owner.displayName)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                if !list.description.isEmpty {
                    Text(list.description)
                        .font(.body)
                }

                HStack(spacing: 8) {
                    if list.isRanked { CollectionsBadge(title: "Ranked", systemImage: "list.number") }
                    if list.visibility == .privateOnly { CollectionsBadge(title: "Only me", systemImage: "lock.fill") }
                    CollectionsBadge(
                        title: "Revision \(list.entriesRevision)",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }

                if !list.tags.isEmpty {
                    Text(list.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(.footnote)
                        .foregroundStyle(.indigo)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func entriesSection(_ list: RemoteMusicList) -> some View {
        Section(list.isRanked ? "Ranking" : "Songs") {
            if detail.entries.isRefreshing && detail.entries.items.isEmpty {
                ProgressView("Loading songs…")
            } else if detail.entries.items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No songs yet").font(.headline)
                    Text(store.isOwnMusicList(list)
                        ? "Edit this list to add songs."
                        : "The author has not added any songs.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("music-list-entries-empty")
            } else {
                ForEach(detail.entries.items) { entry in
                    MusicListEntryRow(entry: entry, isRanked: list.isRanked)
                }
            }

            if detail.entries.hasMore {
                Button {
                    Task { await store.loadMoreMusicListEntries(listID) }
                } label: {
                    if detail.entries.isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Load more songs").frame(maxWidth: .infinity)
                    }
                }
                .disabled(detail.entries.isLoadingMore)
                .accessibilityIdentifier("music-list-entries-load-more")
            }
        }
    }

    @ViewBuilder
    private func engagementSection(_ list: RemoteMusicList) -> some View {
        Section("Appreciation") {
            let likeState = store.musicListLikeState(for: list.id)
            Button {
                Task { _ = await store.setMusicListLiked(list.id, isLiked: likeState != true) }
            } label: {
                Label(likeState == true ? "Liked" : "Like this list", systemImage: likeState == true ? "heart.fill" : "heart")
                    .frame(maxWidth: .infinity)
            }
            .disabled(store.likingMusicListIDs.contains(list.id))
            .accessibilityIdentifier("music-list-like")

            if let engagement = detail.engagement {
                HStack(spacing: 16) {
                    Label("\(engagement.entryCount)", systemImage: "music.note.list")
                    Label("\(engagement.likeCount)", systemImage: "heart")
                    Label("\(engagement.commentCount)", systemImage: "bubble.left")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } else if likeState == nil {
                Text("Loading engagement…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var commentsSection: some View {
        Section("Comments") {
            HStack(alignment: .bottom) {
                TextField("Add a comment", text: $commentBody, axis: .vertical)
                    .lineLimit(1...5)
                    .accessibilityIdentifier("music-list-comment-field")
                Button("Post") {
                    let submitted = commentBody
                    Task {
                        if await store.addMusicListComment(listID: listID, body: submitted) {
                            commentBody = ""
                        }
                    }
                }
                .disabled(
                    commentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || store.commentingMusicListIDs.contains(listID)
                )
                .accessibilityIdentifier("music-list-comment-post")
            }

            if detail.comments.isRefreshing && detail.comments.items.isEmpty {
                ProgressView("Loading comments…")
            } else if detail.comments.items.isEmpty {
                Text("No comments yet.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("music-list-comments-empty")
            } else {
                ForEach(detail.comments.items) { comment in
                    MusicListCommentRow(comment: comment)
                }
            }

            if detail.comments.hasMore {
                Button {
                    Task { await store.loadMoreMusicListComments(listID) }
                } label: {
                    if detail.comments.isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Load more comments").frame(maxWidth: .infinity)
                    }
                }
                .disabled(detail.comments.isLoadingMore)
            }
        }
    }

    private func reload() async {
        _ = await store.refreshMusicListDetail(listID)
        attemptedLoad = true
    }
}

struct MusicListEditorView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @Environment(\.dismiss) private var dismiss
    let list: RemoteMusicList?

    @State private var draft: MusicListDraft
    @State private var showingCatalogPicker = false
    @State private var loadingExistingEntries = false
    @State private var initializedExistingEntries = false
    @State private var saveError: String?

    init(list: RemoteMusicList?) {
        self.list = list
        _draft = State(initialValue: MusicListDraft(
            title: list?.title ?? "",
            description: list?.description ?? "",
            tagsText: list?.tags.joined(separator: ", ") ?? "",
            isRanked: list?.isRanked ?? false,
            visibility: list?.visibility ?? .privateOnly,
            entries: []
        ))
    }

    var body: some View {
        Form {
            if let saveError {
                CollectionsErrorBanner(message: saveError, retry: nil)
            }

            Section("About") {
                TextField("Title", text: $draft.title)
                    .accessibilityIdentifier("music-list-editor-title")
                TextField("Description", text: $draft.description, axis: .vertical)
                    .lineLimit(3...10)
                    .accessibilityIdentifier("music-list-editor-description")
                TextField("Tags, separated by commas", text: $draft.tagsText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("music-list-editor-tags")
            }

            Section("Presentation") {
                Toggle("Rank this list", isOn: $draft.isRanked)
                    .accessibilityIdentifier("music-list-editor-ranked")
                Picker("Audience", selection: $draft.visibility) {
                    ForEach(SocialVisibilityOption.allCases) { visibility in
                        Text(visibility.title).tag(visibility)
                    }
                }
                .accessibilityIdentifier("music-list-editor-visibility")
                Text(draft.isRanked
                    ? "Song positions appear as ranks. Reordering is always preserved."
                    : "Songs remain ordered without displaying rank numbers.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    showingCatalogPicker = true
                } label: {
                    Label("Add songs", systemImage: "plus.circle.fill")
                }
                .disabled(loadingExistingEntries || draft.entries.count >= 1_000)
                .accessibilityIdentifier("music-list-editor-add-songs")

                if loadingExistingEntries {
                    ProgressView("Loading the complete list…")
                } else if draft.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No songs selected").font(.headline)
                        Text("Search connected catalogs to build this collection.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("music-list-editor-entries-empty")
                } else {
                    ForEach($draft.entries) { $entry in
                        MusicListDraftEntryEditorRow(entry: $entry, isRanked: draft.isRanked)
                    }
                    .onDelete { draft.entries.remove(atOffsets: $0) }
                    .onMove { draft.moveEntries(fromOffsets: $0, toOffset: $1) }
                }
            } header: {
                HStack {
                    Text("Songs")
                    Spacer()
                    Text("\(draft.entries.count)/1,000")
                }
            } footer: {
                Text("Use Edit to reorder or remove songs. Notes belong to this list entry only.")
            }
        }
        .navigationTitle(list == nil ? "New list" : "Edit list")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(
                        draft.validationMessage != nil
                        || loadingExistingEntries
                        || store.isCreatingMusicList
                        || list.map { store.mutatingMusicListIDs.contains($0.id) } == true
                    )
                    .accessibilityIdentifier("music-list-editor-save")
            }
        }
        .sheet(isPresented: $showingCatalogPicker) {
            NavigationStack {
                MusicListCatalogPicker(draft: $draft)
            }
            .environmentObject(store)
        }
        .task { await loadExistingDraftIfNeeded() }
        .accessibilityIdentifier("music-list-editor")
    }

    private func loadExistingDraftIfNeeded() async {
        guard let list, !initializedExistingEntries else { return }
        initializedExistingEntries = true
        loadingExistingEntries = true
        defer { loadingExistingEntries = false }

        guard await store.refreshMusicListDetail(list.id) else {
            saveError = store.collaborationMessage
            return
        }
        while store.musicListDetail(for: list.id).entries.hasMore {
            let oldCount = store.musicListDetail(for: list.id).entries.items.count
            await store.loadMoreMusicListEntries(list.id)
            let updated = store.musicListDetail(for: list.id).entries
            if updated.items.count == oldCount && updated.hasMore { break }
        }
        let authoritative = store.musicListDetail(for: list.id)
        guard authoritative.entries.hasMore == false else {
            saveError = "Could not load every song. Close the editor and try again before saving."
            return
        }
        draft = MusicListDraft(
            title: authoritative.list?.title ?? list.title,
            description: authoritative.list?.description ?? list.description,
            tagsText: (authoritative.list?.tags ?? list.tags).joined(separator: ", "),
            isRanked: authoritative.list?.isRanked ?? list.isRanked,
            visibility: authoritative.list?.visibility ?? list.visibility,
            entries: authoritative.entries.items.compactMap { entry in
                guard let track = entry.canonicalTrack else { return nil }
                return MusicListDraftEntry(id: entry.id, track: track.musicListHarmonyTrack, note: entry.note)
            }
        )
        if draft.entries.count != authoritative.entries.items.count {
            saveError = "One or more songs could not be resolved. Reload before saving this list."
        }
    }

    private func save() {
        saveError = draft.validationMessage
        guard saveError == nil else { return }
        Task {
            if let list {
                if await store.updateMusicList(list, from: draft) {
                    dismiss()
                } else {
                    saveError = store.collaborationMessage
                }
            } else if await store.createMusicList(from: draft) != nil {
                dismiss()
            } else {
                saveError = store.collaborationMessage
            }
        }
    }
}

private struct MusicListDraftEntryEditorRow: View {
    @Binding var entry: MusicListDraftEntry
    let isRanked: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TrackArtwork(track: entry.track, size: 44, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.track.title).font(.headline)
                Text(entry.track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Optional note", text: $entry.note, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.footnote)
                    .accessibilityLabel("Note for \(entry.track.title)")
            }
        }
        .accessibilityIdentifier("music-list-draft-entry-\(entry.id.uuidString)")
    }
}

private struct MusicListCatalogPicker: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: MusicListDraft
    @State private var query = ""

    private var search: CatalogSearchState { store.catalogSearchState(for: .lists) }
    private var tracks: [HarmonyTrack] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return store.catalog
        }
        return search.results ?? []
    }

    var body: some View {
        List {
            if search.isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching connected catalogs…").foregroundStyle(.secondary)
                }
            }
            if let message = search.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if !search.isSearching && !query.isEmpty && tracks.isEmpty {
                CollectionsEmptyState(
                    title: "No matching songs",
                    detail: "Try a different song, artist, or album.",
                    actionTitle: nil,
                    action: nil
                )
            }

            ForEach(tracks) { track in
                HStack(spacing: 10) {
                    TrackArtwork(track: track, size: 44, cornerRadius: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.headline)
                        Text("\(track.artist) · \(track.album)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        _ = draft.addTrack(track)
                    } label: {
                        Image(systemName: contains(track) ? "checkmark.circle.fill" : "plus.circle.fill")
                            .font(.title3)
                    }
                    .disabled(contains(track) || draft.entries.count >= 1_000)
                    .accessibilityLabel(contains(track) ? "Already added" : "Add \(track.title)")
                }
            }
        }
        .navigationTitle("Add songs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Song, artist, or album")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task(id: query) {
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await store.searchCatalog(query: query, purpose: .lists)
            } catch {}
        }
        .onDisappear { store.resetCatalogSearch(.lists) }
        .accessibilityIdentifier("music-list-catalog-picker")
    }

    private func contains(_ track: HarmonyTrack) -> Bool {
        var copy = draft
        return !copy.addTrack(track)
    }
}

private struct MusicListEntryRow: View {
    let entry: RemoteMusicListEntry
    let isRanked: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isRanked {
                Text("\(entry.position)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
            }
            if let track = entry.canonicalTrack {
                TrackArtwork(track: track.musicListHarmonyTrack, size: 48, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.headline)
                    Text([track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !entry.note.isEmpty {
                        Text(entry.note)
                            .font(.footnote)
                            .padding(.top, 2)
                    }
                    if let link = track.providerTracks?.compactMap(\.deepLink).first {
                        Link("Open in music app", destination: link)
                            .font(.caption.weight(.semibold))
                    }
                }
            } else {
                Image(systemName: "music.note")
                    .frame(width: 48, height: 48)
                Text("Unavailable song").foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("music-list-entry-\(entry.id.uuidString)")
    }
}

private struct MusicListCommentRow: View {
    @EnvironmentObject private var store: HarmonySessionStore
    let comment: RemoteMusicListComment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(comment.author.displayName).font(.subheadline.bold())
                Spacer()
                Text(comment.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(comment.body).font(.body)
        }
        .swipeActions {
            if store.canDeleteMusicListComment(comment) {
                Button("Delete", role: .destructive) {
                    Task { _ = await store.deleteMusicListComment(comment) }
                }
                .disabled(store.deletingMusicListCommentIDs.contains(comment.id))
            }
        }
        .accessibilityIdentifier("music-list-comment-\(comment.id.uuidString)")
    }
}

private struct MusicListArtworkMosaic: View {
    let entries: [RemoteMusicListEntry]
    let size: CGFloat

    private var visible: [RemoteMusicListEntry] { Array(entries.prefix(4)) }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
            ForEach(0..<4, id: \.self) { index in
                if visible.indices.contains(index), let track = visible[index].canonicalTrack {
                    TrackArtwork(track: track.musicListHarmonyTrack, size: size / 2, cornerRadius: 0)
                } else {
                    ZStack {
                        Color.indigo.opacity(index.isMultiple(of: 2) ? 0.14 : 0.08)
                        Image(systemName: index == 0 ? "music.note.list" : "music.note")
                            .font(.caption)
                            .foregroundStyle(.indigo.opacity(0.7))
                    }
                    .frame(width: size / 2, height: size / 2)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: min(12, size / 8)))
        .accessibilityHidden(true)
    }
}

private struct CollectionsBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.indigo)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.indigo.opacity(0.1), in: Capsule())
    }
}

private struct CollectionsEmptyState: View {
    let title: String
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.title2)
                .foregroundStyle(.indigo)
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

private struct CollectionsErrorBanner: View {
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message).font(.footnote).foregroundStyle(.secondary)
            if let retry { Button("Try again", action: retry) }
        }
        .accessibilityIdentifier("collections-error")
    }
}

private extension RemoteCatalogTrack {
    var musicListHarmonyTrack: HarmonyTrack {
        HarmonyTrack(
            id: id ?? UUID(),
            canonicalTrackID: id,
            title: title,
            artist: artist,
            album: album ?? "",
            duration: TimeInterval(durationMilliseconds ?? 0) / 1_000,
            symbol: "music.note",
            artworkURL: artworkURL,
            isExplicit: isExplicit,
            isrc: isrc,
            mappings: (providerTracks ?? []).compactMap { mapping in
                let provider: MusicProvider
                switch mapping.provider {
                case "spotify": provider = .spotify
                case "apple_music": provider = .appleMusic
                default: return nil
                }
                let availability: ProviderAvailability
                switch mapping.availability {
                case "playable": availability = .playable
                case "open_in_provider": availability = .openInProvider
                default: availability = .unavailable
                }
                return ProviderTrackMapping(
                    provider: provider,
                    providerID: mapping.providerID,
                    storefront: mapping.storefront,
                    availability: availability,
                    deepLinkURL: mapping.deepLink
                )
            }
        )
    }
}
