import SwiftUI

struct ResolvableCanonicalAlbumView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    let album: ReviewableAlbum
    @State private var resolvedAlbum: RemoteCanonicalAlbum?
    @State private var attempted = false

    var body: some View {
        Group {
            if let resolvedAlbum {
                CanonicalAlbumDetailView(
                    album: resolvedAlbum,
                    initialState: store.albumSubjectState(for: resolvedAlbum)
                )
            } else if attempted {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("Album unavailable").font(.headline)
                    Text(store.collaborationMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ProgressView("Opening album…")
            }
        }
        .task {
            resolvedAlbum = await store.resolveCanonicalAlbum(album)
            attempted = true
        }
    }
}

/// A canonical release page: personal state and visible social opinion meet
/// here, while individual review text remains independently addressable.
struct CanonicalAlbumDetailView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    let album: RemoteCanonicalAlbum

    @State private var draft: AlbumSubjectStateDraft
    @State private var savedDraft: AlbumSubjectStateDraft
    @State private var saveMessage: String?
    @State private var isComposingReview = false
    @State private var reviewRating: Double
    @State private var reviewBody = ""
    @State private var reviewIsLoved: Bool
    @State private var reviewContainsSpoilers = false
    @State private var reviewVisibility = SocialVisibilityOption.privateOnly

    init(album: RemoteCanonicalAlbum, initialState: RemoteAlbumSubjectState? = nil) {
        self.album = album
        let draft = AlbumSubjectStateDraft(state: initialState)
        _draft = State(initialValue: draft)
        _savedDraft = State(initialValue: draft)
        _reviewRating = State(initialValue: initialState?.defaultRating ?? 4)
        _reviewIsLoved = State(initialValue: initialState?.isLoved ?? false)
    }

    private var detail: CanonicalAlbumDetailState {
        store.canonicalAlbumDetails[album.id] ?? CanonicalAlbumDetailState(album: album)
    }

    private var isSaving: Bool { store.isSavingAlbumSubjectState(for: album.id) }
    private var isDirty: Bool { draft != savedDraft }

    private var listenedBinding: Binding<Bool> {
        Binding(
            get: { draft.hasListened },
            set: { value in
                draft.hasListened = value
                if value { draft.wantToListen = false }
                if !value { draft.defaultRating = nil }
                saveMessage = nil
            }
        )
    }

    private var lovedBinding: Binding<Bool> {
        Binding(get: { draft.isLoved }, set: { draft.isLoved = $0; saveMessage = nil })
    }

    private var wantBinding: Binding<Bool> {
        Binding(
            get: { draft.wantToListen },
            set: { value in
                draft.wantToListen = value
                if value {
                    draft.hasListened = false
                    draft.defaultRating = nil
                }
                saveMessage = nil
            }
        )
    }

    private var ratingEnabled: Binding<Bool> {
        Binding(
            get: { draft.defaultRating != nil },
            set: { value in
                draft.defaultRating = value ? (draft.defaultRating ?? 4) : nil
                if value {
                    draft.hasListened = true
                    draft.wantToListen = false
                }
                saveMessage = nil
            }
        )
    }

    private var rating: Binding<Double> {
        Binding(
            get: { draft.defaultRating ?? 4 },
            set: { value in
                draft.defaultRating = value
                draft.hasListened = true
                draft.wantToListen = false
                saveMessage = nil
            }
        )
    }

    var body: some View {
        List {
            albumHeader
            ownerStateSection
            reviewActionSection
            providerSection
            visibleRatingsSection
            reviewsSection
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("canonical-album-page-\(album.id.uuidString)")
        .task { await refresh() }
        .refreshable { await refresh(forceDraftRefresh: false) }
        .sheet(isPresented: $isComposingReview) { reviewComposer }
    }

    private var albumHeader: some View {
        Section {
            VStack(spacing: 12) {
                Group {
                    if let artworkURL = album.artworkURL {
                        AsyncImage(url: artworkURL) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "square.stack")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Image(systemName: "square.stack")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 164, height: 164)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityLabel("Album artwork for \(album.title) by \(album.artist ?? "Unknown artist")")
                .accessibilityIdentifier("canonical-album-artwork")

                Text(album.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("canonical-album-title")
                Text(album.artist ?? "Unknown artist")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                let metadata = [
                    album.releaseDate?.prefix(4).description,
                    album.albumType?.capitalized,
                    album.totalTracks.map { "\($0) tracks" }
                ].compactMap { $0 }
                if !metadata.isEmpty {
                    Text(metadata.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityIdentifier("canonical-album-header")
        }
    }

    private var ownerStateSection: some View {
        Section("Your music") {
            Toggle(isOn: listenedBinding) {
                Label("Listened", systemImage: draft.hasListened ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .accessibilityIdentifier("canonical-album-listened")

            Toggle(isOn: lovedBinding) {
                Label("Loved", systemImage: draft.isLoved ? "heart.fill" : "heart")
            }
            .accessibilityIdentifier("canonical-album-loved")

            Toggle(isOn: wantBinding) {
                Label("Want to listen", systemImage: draft.wantToListen ? "bookmark.fill" : "bookmark")
            }
            .accessibilityIdentifier("canonical-album-want")

            Toggle("Set an overall rating", isOn: ratingEnabled)
                .accessibilityIdentifier("canonical-album-rating-toggle")
            RatingPicker(rating: rating)
                .disabled(draft.defaultRating == nil)
                .opacity(draft.defaultRating == nil ? 0.55 : 1)
                .accessibilityIdentifier("canonical-album-rating")

            Text("This is your current album opinion. It does not rewrite song ratings or the rating attached to an earlier review.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                save()
            } label: {
                if isSaving {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Save album status").frame(maxWidth: .infinity)
                }
            }
            .disabled(isSaving || !isDirty)
            .accessibilityIdentifier("canonical-album-save")

            if let saveMessage {
                Text(saveMessage)
                    .font(.footnote)
                    .foregroundStyle(saveMessage.hasPrefix("Saved") ? Color.secondary : Color.red)
            }
        }
        .accessibilityIdentifier("canonical-album-owner-state")
    }

    private var providerSection: some View {
        Section("Listen") {
            let playableMappings = album.providerAlbums.filter { $0.deepLink != nil }
            if playableMappings.isEmpty {
                Text("No provider link is available for this release.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(playableMappings) { mapping in
                    if let deepLink = mapping.deepLink {
                        Link(destination: deepLink) {
                            Label(
                                "Open in \(mapping.provider == "spotify" ? "Spotify" : "Apple Music")",
                                systemImage: "arrow.up.right.square"
                            )
                        }
                        .accessibilityIdentifier("canonical-album-provider-\(mapping.provider)")
                    }
                }
            }
            Text("Provider links open this exact mapped release. Harmony does not stream or rebroadcast audio.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var reviewActionSection: some View {
        Section("Review") {
            Button {
                reviewRating = draft.defaultRating ?? reviewRating
                reviewIsLoved = draft.isLoved
                reviewVisibility = store.reviewsSocialVisibility
                isComposingReview = true
            } label: {
                Label("Write a review", systemImage: "square.and.pencil")
            }
            .disabled(reviewableAlbum == nil)
            .accessibilityIdentifier("canonical-album-write-review")
            Text("Your review keeps its own rating and Loved snapshot. Saving it also makes that latest opinion your current album rating.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var reviewComposer: some View {
        NavigationStack {
            Form {
                Section("Album") {
                    Text(album.title).font(.headline)
                    Text(album.artist ?? "Unknown artist").foregroundStyle(.secondary)
                }
                Section("Rating") {
                    RatingPicker(rating: $reviewRating)
                    TextField("Write a review (optional)", text: $reviewBody, axis: .vertical)
                        .lineLimit(3...10)
                    Toggle("Loved", isOn: $reviewIsLoved)
                    Toggle("Contains spoilers", isOn: $reviewContainsSpoilers)
                }
                Section("Visibility") {
                    Picker("Audience", selection: $reviewVisibility) {
                        ForEach(SocialVisibilityOption.allCases) { visibility in
                            Text(visibility.title).tag(visibility)
                        }
                    }
                }
            }
            .navigationTitle("Review album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isComposingReview = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(reviewVisibility == .followers ? "Publish" : "Save") {
                        guard let reviewableAlbum else { return }
                        Task {
                            let didSave = await store.publishAlbumReview(
                                reviewableAlbum,
                                rating: reviewRating,
                                body: reviewBody,
                                isLoved: reviewIsLoved,
                                containsSpoilers: reviewContainsSpoilers,
                                visibility: reviewVisibility
                            )
                            if didSave {
                                isComposingReview = false
                                await refresh(forceDraftRefresh: true)
                            }
                        }
                    }
                    .disabled(store.isPublishingMusicReview || reviewableAlbum == nil)
                }
            }
        }
    }

    private var reviewableAlbum: ReviewableAlbum? {
        guard let mapping = album.providerAlbums.first,
              let provider = mapping.provider == "spotify"
                ? MusicProvider.spotify
                : (mapping.provider == "apple_music" ? MusicProvider.appleMusic : nil) else {
            return nil
        }
        return ReviewableAlbum(
            canonicalAlbumID: album.id,
            provider: provider,
            providerID: mapping.providerAlbumID,
            storefront: mapping.storefront,
            title: album.title,
            artist: album.artist ?? "Unknown artist",
            artworkURL: album.artworkURL,
            deepLinkURL: mapping.deepLink
        )
    }

    @ViewBuilder
    private var visibleRatingsSection: some View {
        Section("Ratings") {
            if let aggregate = detail.aggregate {
                HStack {
                    VStack(alignment: .leading) {
                        Text(aggregate.averageRating.map { String(format: "%.2f", $0) } ?? "—")
                            .font(.title2.bold())
                        Text("Average across reviews visible to you")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(aggregate.ratingCount) reviews")
                        .font(.subheadline.weight(.semibold))
                }
                AlbumRatingHistogram(buckets: detail.ratingDistribution)
                    .accessibilityIdentifier("canonical-album-rating-distribution")
            } else if detail.isRefreshing {
                ProgressView("Loading rating summary…")
            } else {
                Text("No album ratings yet.").foregroundStyle(.secondary)
            }
        }
    }

    private var reviewsSection: some View {
        Section("Reviews") {
            if detail.isRefreshing && detail.reviews.items.isEmpty {
                ProgressView("Loading reviews…")
            } else if let error = detail.errorMessage, detail.reviews.items.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Could not load album reviews").font(.headline)
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("Try again") { Task { await refresh() } }
                }
            } else if detail.reviews.items.isEmpty {
                Text("No visible reviews for this album yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(detail.reviews.items) { review in
                    ReviewCard(review: review, onEdit: nil)
                        .accessibilityIdentifier("canonical-album-review-\(review.id.uuidString)")
                }
            }

            if detail.reviews.hasMore {
                Button {
                    Task { await store.loadMoreCanonicalAlbumReviews(album.id) }
                } label: {
                    if detail.reviews.isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Load more reviews").frame(maxWidth: .infinity)
                    }
                }
                .disabled(detail.reviews.isLoadingMore)
                .accessibilityIdentifier("canonical-album-reviews-load-more")
            }
        }
    }

    private func save() {
        let submitted = draft.normalizedForSubmission
        Task {
            if await store.saveAlbumSubjectStateDraft(submitted, for: album) {
                let persisted = store.albumSubjectStateDraft(for: album)
                draft = persisted
                savedDraft = persisted
                saveMessage = persisted == submitted
                    ? "Saved"
                    : "Saved. Listened remains on while this album has an active review."
                await store.refreshCanonicalAlbumDetail(album)
            } else {
                saveMessage = store.collaborationMessage.isEmpty
                    ? "Could not save. Your changes are still here—try again."
                    : store.collaborationMessage
            }
        }
    }

    private func refresh(forceDraftRefresh: Bool = true) async {
        await store.refreshCanonicalAlbumDetail(album)
        guard forceDraftRefresh, !isDirty else { return }
        let refreshed = store.albumSubjectStateDraft(for: album)
        draft = refreshed
        savedDraft = refreshed
    }
}

private struct AlbumRatingHistogram: View {
    let buckets: [RemoteCanonicalAlbumRatingBucket]

    private var maximumCount: Int { max(1, buckets.map(\.ratingCount).max() ?? 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(buckets) { bucket in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.orange)
                        .frame(height: bucket.ratingCount == 0
                            ? 2
                            : max(5, 56 * CGFloat(bucket.ratingCount) / CGFloat(maximumCount)))
                    Text(bucket.rating == 0.5 || bucket.rating == 2.5 || bucket.rating == 5
                        ? bucket.rating.formatted(.number.precision(.fractionLength(1)))
                        : " ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(bucket.rating, specifier: "%.1f") stars")
                .accessibilityValue("\(bucket.ratingCount) ratings")
            }
        }
        .frame(height: 78, alignment: .bottom)
    }
}
