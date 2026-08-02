import SwiftUI

struct SessionView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @State private var showingJoinSession = false
    @State private var showingCloseConfirmation = false
    @State private var inviteCode = ""

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LIVE SESSION").font(.caption.weight(.bold)).foregroundColor(.secondary)
                        Text(store.sessionName).font(.title2.bold())
                        Text(store.isLiveSession ? "\(store.members.count) members · \(store.activeMemberIDs.count) here now" : "\(store.members.count) sample members").foregroundColor(.secondary)
						Text(store.collaborationMessage).font(.caption).foregroundColor(.secondary)
                        HStack {
                            ForEach(store.members) { member in
                                Text(member.initials).font(.caption.bold()).frame(width: 30, height: 30).background(Color.indigo.opacity(store.activeMemberIDs.contains(member.id) ? 0.28 : 0.10)).overlay(Circle().stroke(store.activeMemberIDs.contains(member.id) ? Color.green : .clear, lineWidth: 2)).clipShape(Circle()).accessibilityLabel("\(member.name), \(store.activeMemberIDs.contains(member.id) ? "active now" : "not active")")
                            }
                            Spacer()
                            Text(store.inviteCode).font(.caption.monospaced().bold()).padding(8).background(Color.indigo.opacity(0.12)).cornerRadius(8)
                        }
                        if store.isLiveSession {
                            ShareLink(
                                item: "Join my Harmony session \(store.sessionName) with invite code \(store.inviteCode).",
                                subject: Text("Join my Harmony session"),
                                message: Text("Add and arrange music in our shared queue.")
                            ) {
                                Label("Share invite", systemImage: "square.and.arrow.up")
                            }
                        }
                        if store.isLiveSession {
                            Label("Live session active", systemImage: "dot.radiowaves.left.and.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.green)
                        } else {
                            HStack {
                                Button("Start live session") { Task { await store.createLiveSession() } }
                                    .buttonStyle(.borderedProminent)
                                Button("Join session") { showingJoinSession = true }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Now playing") {
                    if let item = store.nowPlaying {
                        HStack {
                            TrackArtwork(track: item.track, size: 44, cornerRadius: 10)
                            VStack(alignment: .leading) {
                                Text(item.track.title).font(.headline)
                                Text(item.track.artist).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button {
                                Task { await store.skipToNext() }
                            } label: {
                                Image(systemName: "forward.end.fill")
                                    .frame(width: 34, height: 34)
                            }
                            .disabled(store.currentMember.role != .conductor || store.queue.count < 2)
                            .accessibilityLabel("Skip to next track")
                            Button {
                                Task { await store.togglePlayback() }
                            } label: {
                                Image(systemName: store.playbackState == .playing ? "pause.fill" : "play.fill").frame(width: 34, height: 34).background(Color.indigo).foregroundColor(.white).clipShape(Circle())
                            }
                            .accessibilityLabel(store.playbackState == .playing ? "Pause" : "Play")
                        }
                    }
                }

                Section(header: HStack { Text("Shared queue"); Spacer(); Text("rev \(store.queueRevision)").font(.caption).foregroundColor(.secondary) }) {
                    ForEach(store.queue) { item in
                        HStack {
                            TrackArtwork(track: item.track, size: 30, cornerRadius: 6)
                            VStack(alignment: .leading) {
                                Text(item.track.title).font(.body.weight(.semibold))
                                Text("\(item.track.artist) · added by \(item.addedBy.name)").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(item.track.durationText).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .onMove(perform: store.move)
                    .onDelete { offsets in
                        offsets.map { store.queue[$0] }.filter(store.canRemove).forEach(store.remove)
                    }
                }
            }
            .navigationTitle("Harmony")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if store.currentMember.role == .conductor {
                        EditButton()
                    }
                    if store.isLiveSession {
                        Menu {
                            Button(store.currentMember.role == .conductor ? "End session" : "Leave session", role: .destructive) {
                                showingCloseConfirmation = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .disabled(store.isClosingSession)
                        .accessibilityLabel("Session options")
                    }
                }
            }
            .confirmationDialog(
                store.currentMember.role == .conductor ? "End this Harmony session?" : "Leave this Harmony session?",
                isPresented: $showingCloseConfirmation,
                titleVisibility: .visible
            ) {
                Button(store.currentMember.role == .conductor ? "End session" : "Leave session", role: .destructive) {
                    Task { await store.closeLiveSession() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(store.currentMember.role == .conductor
                    ? "Members will no longer be able to join or edit this queue."
                    : "You can rejoin later with a valid invite code while the session remains active.")
            }
            .sheet(isPresented: $showingJoinSession) {
                NavigationView {
                    Form {
                        Section("Invitation") {
                            TextField("Invite code", text: $inviteCode)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                        }
                        Section {
                            Button("Join live session") {
                                let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !code.isEmpty else { return }
                                showingJoinSession = false
                                Task { await store.joinLiveSession(inviteCode: code) }
                            }
                        }
                    }
                    .navigationTitle("Join Harmony")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingJoinSession = false }
                        }
                    }
                }
            }
        }
    }
}
