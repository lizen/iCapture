/// Drains a stream into an array. Rethrows if the stream ends with an error.
func collect<T>(_ stream: AsyncThrowingStream<T, Error>) async throws -> [T] {
    var items: [T] = []
    for try await item in stream { items.append(item) }
    return items
}
