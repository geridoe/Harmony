import SwiftUI

struct SessionView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @State private var showingJoinSession = false
    @State private var inviteCode = ""

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LIVE SESSION").font(.caption.weight(.bold)).foregroundColor(.secondary)
                        Text(store.sessionName).font(.title2.bold())
                        Text("\(store.members.count) people are curating together").foregroundColor(.secondary)
						Text(store.collaborationMessage).font(.caption).foregroundColor(.secondary)
                        HStack {
                            ForEach(store.members) { member in
                                Text(member.initials).font(.caption.bold()).frame(width: 30, height: 30).background(Color.indigo.opacity(0.15)).clipShape(Circle())
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
                            Image(systemName: item.track.symbol).font(.title2).foregroundColor(.indigo).frame(width: 44, height: 44).background(Color.indigo.opacity(0.12)).cornerRadius(10)
                            VStack(alignment: .leading) {
                                Text(item.track.title).font(.headline)
                                Text(item.track.artist).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: store.togglePlayback) {
                                Image(systemName: store.playbackState == .playing ? "pause.fill" : "play.fill").frame(width: 34, height: 34).background(Color.indigo).foregroundColor(.white).clipShape(Circle())
                            }
                        }
                    }
                }

                Section(header: HStack { Text("Shared queue"); Spacer(); Text("rev \(store.queueRevision)").font(.caption).foregroundColor(.secondary) }) {
                    ForEach(store.queue) { item in
                        HStack {
                            Image(systemName: item.track.symbol).foregroundColor(.indigo).frame(width: 30)
                            VStack(alignment: .leading) {
                                Text(item.track.title).font(.body.weight(.semibold))
                                Text("\(item.track.artist) · added by \(item.addedBy.name)").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(item.track.durationText).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .onMove(perform: store.move)
                    .onDelete { offsets in offsets.map { store.queue[$0] }.forEach(store.remove) }
                }
            }
            .navigationTitle("Harmony")
            .toolbar {
                if store.currentMember.role == .conductor {
                    EditButton()
                }
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
