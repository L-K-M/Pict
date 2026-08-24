/// Pure `Result` test helpers, shared by several suites.
///
/// Lived in `IconTestSupport` while every icon test imported it, but that file is
/// Core Graphics top to bottom and stays out of the Linux build (LP-01/03). These
/// conveniences are pure, and the `check()`-table tests on Linux need them, so they
/// live here where both platforms can compile them.
extension Result {
    /// The success value, or `nil` — so a test can `XCTUnwrap` it. Named to stay
    /// clear of the `success`/`failure` cases themselves.
    var successValue: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }

    /// The failure value, or `nil`.
    var failureValue: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
