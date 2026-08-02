import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @State private var query = ""
    var tracks: [HarmonyTrack] { query.isEmpty ? store.catalog : store.catalog.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) } }
    var body: some View { NavigationView { List(tracks) { track in HStack { Image(systemName: track.symbol).foregroundColor(.indigo).frame(width: 36, height: 36).background(Color.indigo.opacity(0.12)).cornerRadius(8); VStack(alignment: .leading) { Text(track.title).font(.headline); Text("\(track.artist) · \(track.album)").font(.caption).foregroundColor(.secondary); HStack { ForEach(MusicProvider.allCases) { provider in Text("\(provider.name): \(track.availability(for: provider).label)").font(.caption2).foregroundColor(track.availability(for: provider) == .unavailable ? .secondary : .indigo) } } }; Spacer(); Button { store.add(track) } label: { Image(systemName: "plus.circle.fill").font(.title3) }.disabled(store.queue.contains { $0.track.title == track.title }) } }.searchable(text: $query, prompt: "Search connected catalogs").navigationTitle("Add music") } }
}

struct ConnectionsView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    var body: some View { NavigationView { List(MusicProvider.allCases) { provider in HStack { Image(systemName: provider == .appleMusic ? "apple.logo" : "waveform").font(.title2).frame(width: 36); VStack(alignment: .leading) { Text(provider.name).font(.headline); Text(store.connectedProviders.contains(provider) ? "Connected for this prototype" : "Not connected").font(.caption).foregroundColor(.secondary) }; Spacer(); Image(systemName: store.connectedProviders.contains(provider) ? "checkmark.circle.fill" : "circle").foregroundColor(store.connectedProviders.contains(provider) ? .green : .secondary) } }.navigationTitle("Connections") } }
}
