import Foundation
import CoreLocation

// MARK: - 地点模型

/// 一条可复用的地点记录（用于「最近搜索」与「收藏地点」）
struct SavedPlace: Identifiable, Codable, Hashable {

    var id: UUID
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var savedAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// 用于界面展示的副标题，地址为空时给出兜底文案
    var subtitle: String {
        address.isEmpty ? "未获取到详细地址" : address
    }

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        latitude: Double,
        longitude: Double,
        savedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.savedAt = savedAt
    }

    init(name: String, address: String, coordinate: CLLocationCoordinate2D, savedAt: Date = Date()) {
        self.init(
            name: name,
            address: address,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            savedAt: savedAt
        )
    }

    /// 判断两个记录是否指向同一个地点
    func isSamePlace(as other: SavedPlace) -> Bool {
        if name == other.name {
            return true
        }
        let latGap = abs(latitude - other.latitude)
        let lonGap = abs(longitude - other.longitude)
        return latGap < 0.00015 && lonGap < 0.00015
    }
}

// MARK: - 地点存储（最近搜索 + 收藏）

@MainActor
final class PlaceStore: ObservableObject {

    /// 最近搜索，按时间倒序
    @Published private(set) var recents: [SavedPlace] = []
    /// 收藏地点，按添加时间倒序
    @Published private(set) var favorites: [SavedPlace] = []

    private let recentsKey = "naviapp.recentPlaces.v2"
    private let favoritesKey = "naviapp.favoritePlaces.v2"
    private let maxRecents = 10
    private let maxFavorites = 12

    init() {
        load()
    }

    // MARK: 最近搜索

    func recordRecent(_ place: SavedPlace) {
        guard !place.name.isEmpty else { return }

        var list = recents.filter { !$0.isSamePlace(as: place) }
        list.insert(place, at: 0)
        if list.count > maxRecents {
            list = Array(list.prefix(maxRecents))
        }
        recents = list
        persist(list, key: recentsKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        persist(recents, key: recentsKey)
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: recentsKey)
    }

    // MARK: 收藏地点

    func addFavorite(_ place: SavedPlace) {
        guard !place.name.isEmpty else { return }
        guard !favorites.contains(where: { $0.isSamePlace(as: place) }) else { return }

        var list = favorites
        list.insert(place, at: 0)
        if list.count > maxFavorites {
            list = Array(list.prefix(maxFavorites))
        }
        favorites = list
        persist(list, key: favoritesKey)
    }

    func removeFavorite(_ place: SavedPlace) {
        favorites.removeAll { $0.id == place.id }
        persist(favorites, key: favoritesKey)
    }

    func isFavorite(_ place: SavedPlace) -> Bool {
        favorites.contains { $0.isSamePlace(as: place) }
    }

    // MARK: 持久化

    private func persist(_ list: [SavedPlace], key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        if let data = UserDefaults.standard.data(forKey: recentsKey),
           let list = try? decoder.decode([SavedPlace].self, from: data) {
            recents = list
        }
        if let data = UserDefaults.standard.data(forKey: favoritesKey),
           let list = try? decoder.decode([SavedPlace].self, from: data) {
            favorites = list
        }
    }
}
