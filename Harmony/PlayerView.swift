import SwiftUI

struct SessionView: View {
    @EnvironmentObject private var store: HarmonySessionStore

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LIVE SESSION").font(.caption.weight(.bold)).foregroundColor(.secondary)
                        Text(store.sessionName).font(.title2.bold())
                        Text("\(store.members.count) people are curating together").foregroundColor(.secondary)
                        HStack {
                            ForEach(store.members) { member in
                                Text(member.initials).font(.caption.bold()).frame(width: 30, height: 30).background(Color.indigo.opacity(0.15)).clipShape(Circle())
                            }
                            Spacer()
                            Text(store.inviteCode).font(.caption.monospaced().bold()).padding(8).background(Color.indigo.opacity(0.12)).cornerRadius(8)
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
            .toolbar { EditButton() }
        }
    }
}
