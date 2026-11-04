import EscortKit
import MapKit
import SwiftUI

/**
 开始护航确认页（3.4、4.3）：本次担保人（常驻默认勾，临时第一次默认勾），每人名字下写她能看到什么；
 关了通知或 7 天没打开 App 的人标红“可能收不到通知”，全都标红就不让开始；
 间隔默认 30 分钟，可改 15 / 60；可选“今晚回哪”。
 */
struct StartEscortView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var options: StartOptions?
    @State private var chosen: Set<String> = []
    @State private var interval = 30
    @State private var destination: Destination = .home
    @State private var tonightPlace: HomePlace?
    @State private var pickingPlace = false
    @State private var error: String?
    @State private var showLocationNote = !UserDefaults.standard.bool(forKey: "locationNoteShown")

    enum Destination: Hashable { case home, other }

    private var homePlaces: [HomePlace] { HomePlaceStore.load() }

    var body: some View {
        NavigationStack {
            Form {
                if let o = options {
                    Section {
                        if o.candidates.isEmpty {
                            Text("还没有担保人。先回首页点 + 加一个你信任的人。").foregroundStyle(.secondary)
                        }
                        ForEach(o.candidates) { c in
                            Button { toggle(c, max: o.maxGuardians) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: chosen.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(chosen.contains(c.id) ? Theme.accent : .secondary)
                                    AvatarView(name: c.guardian.displayName, url: c.guardian.avatarUrl, size: 36,
                                               tint: c.tier == .temporary ? Theme.temporary : Theme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack { Text(c.guardian.displayName); TierBadge(tier: c.tier) }
                                        Text(c.canSee).font(.caption).foregroundStyle(.secondary)
                                        if let w = c.readiness?.warning {
                                            Text(w).font(.caption).foregroundStyle(Theme.danger)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("本次担保人（最多 \(o.maxGuardians) 人）")
                    }

                    Section("多久签到一次") {
                        Picker("间隔", selection: $interval) {
                            ForEach(o.intervals, id: \.self) { Text("\($0) 分钟").tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    Section {
                        Picker("今晚回哪", selection: $destination) {
                            Text(homePlaces.first?.name ?? "家").tag(Destination.home)
                            Text(tonightPlace?.name ?? "别的地方…").tag(Destination.other)
                        }
                        .onChange(of: destination) { _, d in if d == .other { pickingPlace = true } }
                        if homePlaces.isEmpty {
                            NavigationLink("设置家的位置，到家时提醒你结束") { HomePlacesView() }
                                .font(.footnote)
                        }
                    } footer: {
                        Text("到了这个地方会问你“到了吗”。地点只存在这台手机上。")
                    }

                    if let error {
                        Section { Text(error).foregroundStyle(Theme.danger) }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("开始护航")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                AsyncButton { try await start() } label: {
                    Text(allNotReady ? "选中的人都可能收不到通知" : "开始").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(chosen.isEmpty || allNotReady)
                .padding()
            }
            .task { await load() }
            .sheet(isPresented: $pickingPlace) {
                PlacePicker(title: "今晚回哪", initial: nil) { place in
                    tonightPlace = place
                    if place == nil { destination = .home }
                }
            }
            .alert("位置只在护航时使用", isPresented: $showLocationNote) {
                Button("知道了") { UserDefaults.standard.set(true, forKey: "locationNoteShown") }
            } message: {
                Text("行踪轨迹属于敏感个人信息。护航开始后才上报位置，只有这次选中的人能看到；结束就停止，没有出事的轨迹 24 小时后删除。接下来系统会问你位置权限，选“使用 App 时允许”即可。")
            }
        }
    }

    private var allNotReady: Bool {
        guard let o = options, !chosen.isEmpty else { return false }
        return o.candidates.filter { chosen.contains($0.id) }.allSatisfy { $0.readiness?.ready == false }
    }

    private func toggle(_ c: StartCandidate, max: Int) {
        if chosen.contains(c.id) { chosen.remove(c.id) } else if chosen.count < max { chosen.insert(c.id) }
    }

    private func load() async {
        do {
            let o = try await model.api.startOptions()
            options = o
            interval = o.defaultInterval
            chosen = Set(o.candidates.filter(\.defaultChecked).map(\.id))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func start() async throws {
        model.location.requestPermissionIfNeeded()
        model.location.tonightDestination = destination == .other ? tonightPlace : nil
        let label = destination == .other ? tonightPlace?.name : homePlaces.first?.name
        let e = try await model.api.startEscort(guardianIds: Array(chosen), intervalMin: interval, from: "phone", destinationLabel: label)
        model.started(e)
        dismiss()
    }
}

/// 地图选点：默认定在当前位置，可以拖动地图；画出范围圈
struct PlacePicker: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initial: HomePlace?
    let onDone: (HomePlace?) -> Void

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var center: CLLocationCoordinate2D?
    @State private var name = ""
    @State private var radius: Double = 150

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Map(position: $position) {
                        if let c = center {
                            MapCircle(center: c, radius: radius).foregroundStyle(Theme.accent.opacity(0.15)).stroke(Theme.accent, lineWidth: 1.5)
                        }
                        UserAnnotation()
                    }
                    .onMapCameraChange(frequency: .continuous) { ctx in center = ctx.region.center }
                    Image(systemName: "mappin").font(.largeTitle).foregroundStyle(Theme.danger).offset(y: -16)
                }
                Form {
                    TextField("名字，比如 家、宿舍、朋友家", text: $name)
                    Picker("范围", selection: $radius) {
                        ForEach(HomePlace.radiusOptions, id: \.self) { Text("\(Int($0)) 米").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .frame(height: 170)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { onDone(nil); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let c = center else { return }
                        onDone(HomePlace(id: initial?.id ?? UUID(), name: name.isEmpty ? "家" : name, lat: c.latitude, lng: c.longitude, radiusM: radius))
                        dismiss()
                    }
                    .disabled(center == nil)
                }
            }
            .onAppear {
                if let p = initial {
                    name = p.name
                    radius = p.radiusM
                    let c = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng)
                    center = c
                    position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 800, longitudinalMeters: 800))
                }
            }
        }
    }
}
