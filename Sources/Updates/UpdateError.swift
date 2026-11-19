/// Why a check did not end well.
/// Its text reaches `update.json` and `signd update`, so it contains no secret.
struct UpdateError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
}
