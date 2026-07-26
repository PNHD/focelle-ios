import Foundation

@MainActor
final class AIAnalysisModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case ready(AICompositionResponse, selected: Int)
        case failed(AIClientError)
    }

    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private let send: @Sendable (Data, SceneMeasurement?) async throws -> AICompositionResponse

    init(
        send: @escaping @Sendable (Data, SceneMeasurement?) async throws
            -> AICompositionResponse = AIClient.analyze
    ) {
        self.send = send
    }

    func analyze(_ preview: Data, measurement: SceneMeasurement?) {
        task?.cancel()
        state = .loading
        task = Task {
            do {
                let result = try await send(preview, measurement)
                guard !Task.isCancelled else { return }
                state = .ready(result, selected: 0)
            } catch is CancellationError {
                state = .idle
            } catch let error as AIClientError {
                state = .failed(error)
            } catch {
                state = .failed(.invalidResponse)
            }
        }
    }

    func select(_ index: Int) -> AICompositionPlan? {
        guard case let .ready(result, _) = state, result.plans.indices.contains(index) else {
            return nil
        }
        state = .ready(result, selected: index)
        return result.plans[index]
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    func fail(_ error: AIClientError) {
        task?.cancel()
        state = .failed(error)
    }
}
