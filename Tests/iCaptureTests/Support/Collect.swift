/// 스트림을 끝까지 읽어 배열로 모은다. 스트림이 에러로 끝나면 그대로 던진다.
func collect<T>(_ stream: AsyncThrowingStream<T, Error>) async throws -> [T] {
    var items: [T] = []
    for try await item in stream { items.append(item) }
    return items
}
