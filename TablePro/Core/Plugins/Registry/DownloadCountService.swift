//
//  DownloadCountService.swift
//  TablePro
//

import Foundation
import os

@MainActor @Observable
final class DownloadCountService {
    static let shared = DownloadCountService()

    private var counts: [String: Int] = [:]
    private var lastFetchDate: Date?
    private static let cooldown: TimeInterval = 300 // 5 minutes
    private static let logger = Logger(subsystem: "com.TablePro", category: "DownloadCountService")

    // swiftlint:disable:next force_unwrapping
    private static let releasesURL = URL(string: "https://api.github.com/repos/datlechin/TablePro/releases?per_page=100")!

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public

    func downloadCount(for pluginId: String) -> Int? {
        counts[pluginId]
    }

    func fetchCounts(for manifest: RegistryManifest?) async {
        guard let manifest else { return }

        if let lastFetchDate, Date().timeIntervalSince(lastFetchDate) < Self.cooldown {
            return
        }

        do {
            let releases = try await fetchReleases()
            let pluginReleases = releases.filter { $0.tagName.hasPrefix("plugin-") }
            let urlToPluginId = buildURLMap(from: manifest)

            var totals: [String: Int] = [:]
            for release in pluginReleases {
                for asset in release.assets {
                    if let pluginId = urlToPluginId[asset.browserDownloadUrl] {
                        totals[pluginId, default: 0] += asset.downloadCount
                    }
                }
            }

            counts = totals
            lastFetchDate = Date()
            Self.logger.info("Fetched download counts for \(totals.count) plugin(s)")
        } catch {
            Self.logger.error("Failed to fetch download counts: \(error.localizedDescription)")
        }
    }

    // MARK: - GitHub API

    private func fetchReleases() async throws -> [GitHubRelease] {
        var request = URLRequest(url: Self.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([GitHubRelease].self, from: data)
    }

    // MARK: - URL Mapping

    private func buildURLMap(from manifest: RegistryManifest) -> [String: String] {
        var map: [String: String] = [:]
        for plugin in manifest.plugins {
            if let binaries = plugin.binaries {
                for binary in binaries {
                    map[binary.downloadURL] = plugin.id
                }
            }
            if let url = plugin.downloadURL {
                map[url] = plugin.id
            }
        }
        return map
    }
}

// MARK: - GitHub API Models

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]
}

private struct GitHubAsset: Decodable {
    let name: String
    let downloadCount: Int
    let browserDownloadUrl: String
}
