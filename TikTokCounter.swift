import AppKit
import Combine
import SwiftUI

@main
struct TikTokCounterApp: App {
    @StateObject private var model = DashboardModel()

    var body: some Scene {
        Window("TIKTOK CONTADOR", id: "dashboard") {
            CounterDashboard(model: model)
                .frame(minWidth: 760, minHeight: 660)
        }
        .defaultSize(width: 860, height: 740)
        .windowResizability(.contentMinSize)
    }
}

struct SavedVideo: Codable, Identifiable, Sendable {
    let id: String
    let handle: String
    var follows: Bool

    var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.tiktok.com"
        components.path = "/@\(handle)/video/\(id)"
        return components.url!
    }

    var label: String { "@\(handle) · …\(id.suffix(7))" }

    static func from(_ text: String) -> SavedVideo? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              ["tiktok.com", "www.tiktok.com", "m.tiktok.com"].contains(host),
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, parts[0].hasPrefix("@"), parts[1] == "video" else { return nil }
        let handle = String(parts[0].dropFirst())
        let id = String(parts[2])
        guard handle.range(of: #"^[A-Za-z0-9_.]{1,24}$"#, options: .regularExpression) != nil,
              id.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil else { return nil }
        return SavedVideo(id: id, handle: handle, follows: true)
    }
}

struct Counts: Codable, Sendable {
    let playCount: Int
    let diggCount: Int
    let commentCount: Int
    let shareCount: Int

    enum CodingKeys: String, CodingKey {
        case playCount = "play_count"
        case diggCount = "digg_count"
        case commentCount = "comment_count"
        case shareCount = "share_count"
    }

    var isValid: Bool { [playCount, diggCount, commentCount, shareCount].allSatisfy { $0 >= 0 } }
}

struct VideoSnapshot: Codable, Sendable {
    var counts: Counts?
    var lastSuccess: Date?
    var lastAttempt: Date
    var error: String?
}

private struct VideoResponse: Decodable {
    let id: String
    let counts: Counts

    enum CodingKeys: String, CodingKey { case id }

    init(from decoder: Decoder) throws {
        id = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .id)
        counts = try Counts(from: decoder)
    }
}

private enum QueryResult: Sendable {
    case success(Counts)
    case failure(String)

    static func fetch(_ video: SavedVideo) -> Self {
        let cli = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TikTok Contador/tt")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            return .failure("Falta instalar tt. Consulta las instrucciones del README.")
        }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["video", video.url.absoluteString, "--quiet", "--output", "json", "--no-cache", "--timeout", "20s", "--retries", "0"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure("No se pudo abrir la herramienta de consulta de TikTok.")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        switch process.terminationStatus {
        case 0:
            guard let videos = try? JSONDecoder().decode([VideoResponse].self, from: data),
                  let response = videos.first(where: { $0.id == video.id }),
                  response.counts.isValid else {
                return .failure("TikTok no devolvió contadores válidos para este vídeo.")
            }
            return .success(response.counts)
        case 3, 6:
            return .failure("El vídeo no está disponible. Comprueba que siga publicado y sea público.")
        case 4:
            return .failure("TikTok bloqueó la consulta. Puedes volver a intentarlo más tarde.")
        default:
            return .failure("No se pudo actualizar el vídeo. Inténtalo de nuevo más tarde.")
        }
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var videos: [SavedVideo]
    @Published private(set) var selectedID: String
    @Published private(set) var intervalMinutes: Int
    @Published private(set) var isMonitoring = false
    @Published private(set) var activeQueries: Set<String> = []
    @Published private(set) var snapshots: [String: VideoSnapshot]
    @Published var link = ""
    @Published private(set) var linkError: String?
    private var monitorTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        let storedVideos = defaults.data(forKey: "savedTikTokVideos")
            .flatMap { try? JSONDecoder().decode([SavedVideo].self, from: $0) }
        let loadedVideos = storedVideos ?? []
        videos = loadedVideos
        let lastSelection = defaults.string(forKey: "selectedTikTokVideo")
        selectedID = loadedVideos.first(where: { $0.id == lastSelection })?.id ?? loadedVideos.first?.id ?? ""
        let storedInterval = defaults.integer(forKey: "monitorIntervalMinutes")
        intervalMinutes = [15, 30, 60].contains(storedInterval) ? storedInterval : 60
        snapshots = defaults.data(forKey: "tiktokVideoSnapshots")
            .flatMap { try? JSONDecoder().decode([String: VideoSnapshot].self, from: $0) } ?? [:]
    }

    var selectedVideo: SavedVideo? { videos.first { $0.id == selectedID } }
    var selectedSnapshot: VideoSnapshot? { snapshots[selectedID] }
    var followedCount: Int { videos.filter(\.follows).count }

    func select(_ id: String) {
        selectedID = id
        defaults.set(id, forKey: "selectedTikTokVideo")
    }

    func addLink() {
        guard let video = SavedVideo.from(link) else {
            linkError = "Pega el enlace completo del vídeo de TikTok."
            return
        }
        link = ""
        linkError = nil
        if !videos.contains(where: { $0.id == video.id }) {
            videos.append(video)
            saveVideos()
        }
        select(video.id)
    }

    func removeSelected() {
        guard let index = videos.firstIndex(where: { $0.id == selectedID }) else { return }
        videos.remove(at: index)
        select(videos.isEmpty ? "" : videos[min(index, videos.count - 1)].id)
        saveVideos()
        if followedCount == 0 { stopMonitoring() }
    }

    func setFollowed(_ follows: Bool, for id: String) {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        videos[index].follows = follows
        saveVideos()
        if followedCount == 0 { stopMonitoring() }
        if follows, isMonitoring {
            let video = videos[index]
            Task { await check(video) }
        }
    }

    func setInterval(_ minutes: Int) {
        intervalMinutes = minutes
        defaults.set(minutes, forKey: "monitorIntervalMinutes")
        if isMonitoring { startMonitoring(immediately: false) }
    }

    func startMonitoring(immediately: Bool = true) {
        guard followedCount > 0 else { return }
        monitorTask?.cancel()
        isMonitoring = true
        monitorTask = Task {
            if immediately { await checkFollowedVideos() }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(intervalMinutes * 60))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await checkFollowedVideos()
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        isMonitoring = false
    }

    func check(_ video: SavedVideo) async {
        guard activeQueries.insert(video.id).inserted else { return }
        defer { activeQueries.remove(video.id) }
        let result = await Task.detached(priority: .utility) {
            QueryResult.fetch(video)
        }.value

        let now = Date()
        switch result {
        case .success(let counts):
            snapshots[video.id] = VideoSnapshot(counts: counts, lastSuccess: now, lastAttempt: now)
        case .failure(let message):
            var snapshot = snapshots[video.id] ?? VideoSnapshot(lastAttempt: now)
            snapshot.lastAttempt = now
            snapshot.error = message
            snapshots[video.id] = snapshot
        }
        defaults.set(try? JSONEncoder().encode(snapshots), forKey: "tiktokVideoSnapshots")
    }

    private func checkFollowedVideos() async {
        let targets = videos.filter(\.follows)
        for video in targets {
            guard !Task.isCancelled else { return }
            if videos.contains(where: { $0.id == video.id && $0.follows }) {
                await check(video)
            }
        }
    }

    private func saveVideos() {
        defaults.set(try? JSONEncoder().encode(videos), forKey: "savedTikTokVideos")
    }
}

struct CounterDashboard: View {
    @ObservedObject var model: DashboardModel

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    private let red = Color(red: 1.0, green: 0.13, blue: 0.25)
    private let background = Color(red: 0.055, green: 0.063, blue: 0.078)
    private let metalGradient = LinearGradient(
        colors: [Color(red: 0.91, green: 0.94, blue: 0.98), Color(red: 0.57, green: 0.63, blue: 0.72), Color(red: 0.96, green: 0.97, blue: 1.0)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    private let panelGradient = LinearGradient(
        stops: [
            .init(color: Color(red: 0.27, green: 0.30, blue: 0.35), location: 0),
            .init(color: Color(red: 0.13, green: 0.15, blue: 0.19), location: 0.18),
            .init(color: Color(red: 0.22, green: 0.24, blue: 0.28), location: 0.52),
            .init(color: Color(red: 0.10, green: 0.12, blue: 0.16), location: 1)
        ], startPoint: .topLeading, endPoint: .bottomTrailing
    )
    private let numberFormat = NumberFormatter()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                videoSelector

                if let video = model.selectedVideo {
                    let counts = model.selectedSnapshot?.counts
                    LazyVGrid(columns: columns, spacing: 14) {
                        metric("Reproducciones", value: counts?.playCount, symbol: "play.fill")
                        metric("Me gusta", value: counts?.diggCount, symbol: "heart.fill")
                        metric("Comentarios", value: counts?.commentCount, symbol: "text.bubble.fill")
                        metric("Compartidos", value: counts?.shareCount, symbol: "arrowshape.turn.up.right.fill")
                    }

                    statusBlock(for: video)
                    controls(for: video)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            ZStack {
                background.ignoresSafeArea()
                RadialGradient(colors: [Color.white.opacity(0.075), .clear], center: .topLeading, startRadius: 10, endRadius: 700)
                    .ignoresSafeArea()
                LinearGradient(colors: [Color.white.opacity(0.025), .clear, Color.black.opacity(0.22)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .task(id: model.selectedID) {
            if let video = model.selectedVideo,
               model.selectedSnapshot == nil {
                await model.check(video)
            }
        }
        .onAppear {
            numberFormat.numberStyle = .decimal
            numberFormat.locale = Locale(identifier: "es_ES")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TIKTOK CONTADOR")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(2.4)
                .foregroundStyle(red)
            Text(model.selectedVideo.map { "@\($0.handle)" } ?? "Mis vídeos")
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .foregroundStyle(metalGradient)
        }
    }

    private var videoSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let video = model.selectedVideo {
                HStack(spacing: 12) {
                    Picker("Vídeo", selection: Binding(get: { model.selectedID }, set: model.select)) {
                        ForEach(model.videos) { saved in
                            Text(saved.label).tag(saved.id)
                        }
                    }
                    .frame(maxWidth: 350)
                    Toggle("Seguir este vídeo", isOn: Binding(
                        get: { video.follows },
                        set: { model.setFollowed($0, for: video.id) }
                    ))
                    .toggleStyle(.checkbox)
                    Spacer()
                    Button("Quitar enlace", role: .destructive, action: model.removeSelected)
                        .buttonStyle(.bordered)
                }
            }
            HStack(spacing: 10) {
                TextField("Pega el enlace del vídeo de TikTok", text: $model.link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.addLink)
                Button("Añadir vídeo", action: model.addLink)
                    .buttonStyle(.bordered)
                    .disabled(model.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.linkError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(panelGradient.opacity(0.72), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(metalGradient.opacity(0.27), lineWidth: 1))
    }

    private func metric(_ title: String, value: Int?, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(red)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.58))
            }
            Text(value.map { numberFormat.string(from: NSNumber(value: $0)) ?? String($0) } ?? "—")
                .font(.system(size: 34, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, minHeight: 73, alignment: .leading)
        .padding(18)
        .background(panelGradient, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(metalGradient.opacity(0.52), lineWidth: 1))
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 15).fill(LinearGradient(colors: [.white.opacity(0.27), .clear], startPoint: .top, endPoint: .bottom))
                .frame(height: 1)
                .padding(.horizontal, 12)
        }
        .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 9)
    }

    private func statusBlock(for video: SavedVideo) -> some View {
        let snapshot = model.selectedSnapshot
        let isLoading = model.activeQueries.contains(video.id)
        return VStack(alignment: .leading, spacing: 6) {
            if isLoading {
                Label("Consultando TikTok…", systemImage: "arrow.clockwise")
                    .foregroundStyle(.white.opacity(0.78))
            } else if let error = snapshot?.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if snapshot?.counts != nil {
                Label("Lectura disponible", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Text(lastUpdatedText(snapshot?.lastSuccess))
                .foregroundStyle(.white.opacity(0.65))
        }
        .font(.system(size: 12))
        .padding(14)
        .background(panelGradient.opacity(0.72), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(metalGradient.opacity(0.27), lineWidth: 1))
    }

    private func controls(for video: SavedVideo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Consultar cada")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.66))
                Picker("Frecuencia", selection: Binding(
                    get: { model.intervalMinutes },
                    set: { model.setInterval($0) }
                )) {
                    Text("15 minutos").tag(15)
                    Text("30 minutos").tag(30)
                    Text("60 minutos").tag(60)
                }
                .labelsHidden()
                .frame(width: 140)

                Button {
                    if model.isMonitoring { model.stopMonitoring() }
                    else { model.startMonitoring() }
                } label: {
                    Label(model.isMonitoring ? "Pausar" : "Iniciar seguimiento", systemImage: model.isMonitoring ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .tint(red)
                .disabled(model.followedCount == 0)

                Button {
                    Task { await model.check(video) }
                } label: {
                    Label(model.activeQueries.contains(video.id) ? "Consultando…" : "Consultar ahora", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.activeQueries.contains(video.id))

                Spacer(minLength: 4)
                Button {
                    NSWorkspace.shared.open(video.url)
                } label: {
                    Label("Abrir vídeo", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .tint(red)
            }

            Text(monitorStatus)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(14)
        .background(panelGradient.opacity(0.68), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(metalGradient.opacity(0.24), lineWidth: 1))
    }

    private var monitorStatus: String {
        if model.followedCount == 0 { return "Marca los vídeos que quieras seguir." }
        if model.isMonitoring {
            return model.followedCount == 1
                ? "Siguiendo 1 vídeo mientras la app esté abierta."
                : "Siguiendo \(model.followedCount) vídeos mientras la app esté abierta."
        }
        return "Seguimiento automático pausado."
    }

    private func lastUpdatedText(_ date: Date?) -> String {
        guard let date else {
            return "Todavía no hay una lectura válida."
        }
        return "Última lectura: " + date.formatted(date: .abbreviated, time: .shortened)
    }
}
