import Foundation
import Observation

/// Holds each provider's key status and its live model list.
@Observable
final class ModelCatalog {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(Date)
        case failed(String)
    }

    private(set) var models: [AIProviderKind: [AIModelInfo]] = [:]
    private(set) var states: [AIProviderKind: LoadState] = [:]
    private(set) var hasKey: [AIProviderKind: Bool] = [:]

    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
        refreshKeyStatus()
    }

    var allModels: [AIModelInfo] {
        AIProviderKind.allCases.flatMap { models[$0] ?? [] }
    }

    func state(for provider: AIProviderKind) -> LoadState {
        states[provider] ?? .idle
    }

    func refreshKeyStatus() {
        for provider in AIProviderKind.allCases {
            hasKey[provider] = keychain.contains(provider.keychainAccount)
        }
    }

    /// Saves the key only after the provider accepts it.
    func saveAndVerify(key rawKey: String, for provider: AIProviderKind) async -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            states[provider] = .failed(AIProviderError.missingKey.localizedDescription)
            return false
        }
        states[provider] = .loading
        do {
            let list = try await provider.client.listModels(apiKey: key)
            try keychain.set(key, for: provider.keychainAccount)
            apply(list, for: provider)
            hasKey[provider] = true
            return true
        } catch {
            states[provider] = .failed(error.localizedDescription)
            return false
        }
    }

    /// Re-lists models using the stored key.
    func refresh(_ provider: AIProviderKind) async {
        let key: String?
        do { key = try keychain.get(provider.keychainAccount) } catch {
            states[provider] = .failed(error.localizedDescription)
            return
        }
        guard let key else {
            states[provider] = .failed(AIProviderError.missingKey.localizedDescription)
            hasKey[provider] = false
            return
        }
        states[provider] = .loading
        do {
            apply(try await provider.client.listModels(apiKey: key), for: provider)
        } catch {
            states[provider] = .failed(error.localizedDescription)
        }
    }

    func refreshAllConnected() async {
        for provider in AIProviderKind.allCases where hasKey[provider] == true {
            await refresh(provider)
        }
    }

    func removeKey(for provider: AIProviderKind) {
        try? keychain.delete(provider.keychainAccount)
        hasKey[provider] = false
        models[provider] = nil
        states[provider] = .idle
    }

    /// Only call after a fresh Face ID check.
    func revealKey(for provider: AIProviderKind) -> String? {
        try? keychain.get(provider.keychainAccount)
    }

    private func apply(_ list: [AIModelInfo], for provider: AIProviderKind) {
        models[provider] = list.sorted(by: TierSuggester.newerFirst)
        states[provider] = .loaded(Date())
    }
}
