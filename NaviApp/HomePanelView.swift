import SwiftUI

/// 首页底部面板：搜索框 + 收藏地点 + 最近搜索
struct HomePanelView: View {

    @Binding var searchText: String

    let recents: [SavedPlace]
    let favorites: [SavedPlace]
    let isSearching: Bool
    let isRecording: Bool

    var onSearch: () -> Void
    var onVoiceTap: () -> Void
    var onAddFavorite: () -> Void
    var onSelectPlace: (SavedPlace) -> Void
    var onDeleteRecent: (SavedPlace) -> Void
    var onClearRecents: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            grabber

            searchBar
                .padding(.horizontal, 14)
                .padding(.top, 10)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    favoritesSection
                    recentsSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 30)
            }
        }
        .background(panelBackground)
    }

    // MARK: - 顶部拖动条

    private var grabber: some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 38, height: 4)
            .padding(.top, 9)
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))

            TextField("搜索地点或地址", text: $searchText)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .submitLabel(.search)
                .onSubmit {
                    onSearch()
                }

            if isSearching {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(Color(hex: "00F2FE"))
            }

            voiceButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private var voiceButton: some View {
        Button {
            onVoiceTap()
        } label: {
            Image(systemName: isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isRecording ? Color(hex: "FF416C") : Color.white.opacity(0.7))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 收藏地点

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("地点")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    addFavoriteButton

                    ForEach(favorites) { place in
                        favoriteChip(place)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var addFavoriteButton: some View {
        Button {
            onAddFavorite()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 56, height: 56)
                    Image(systemName: "plus")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(Color(hex: "00F2FE"))
                }
                Text("添加")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .frame(width: 60)
        }
        .buttonStyle(.plain)
    }

    private func favoriteChip(_ place: SavedPlace) -> some View {
        Button {
            onSelectPlace(place)
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 56, height: 56)
                    Image(systemName: "star.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color(hex: "FFD166"))
                }
                Text(place.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .frame(width: 60)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 最近搜索

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("最近搜索")
                Spacer()
                if !recents.isEmpty {
                    Button {
                        onClearRecents()
                    } label: {
                        Text("清空")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }

            if recents.isEmpty {
                emptyRecentsHint
            } else {
                VStack(spacing: 8) {
                    ForEach(recents) { place in
                        recentRow(place)
                    }
                }
            }
        }
    }

    private var emptyRecentsHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 12))
            Text("还没有搜索记录，试试搜索目的地")
                .font(.system(size: 12))
        }
        .foregroundStyle(.white.opacity(0.4))
        .padding(.vertical, 16)
    }

    private func recentRow(_ place: SavedPlace) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.09))
                    .frame(width: 38, height: 38)
                Image(systemName: "house.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(place.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button {
                onDeleteRecent(place)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectPlace(place)
        }
    }

    // MARK: - 公共片段

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 26)
            .fill(Color(hex: "0B0F17").opacity(0.97))
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .ignoresSafeArea(edges: .bottom)
    }
}
