## Rust

- Do not use `unsafe` without a `// SAFETY:` comment explaining the invariant being upheld.
- Prefer returning `Result<T, E>` over panicking; use `?` for propagation.
- Derive `Clone`, `Debug`, and other standard traits only when they are meaningful for the type.
- Run `cargo clippy -- -D warnings` and `cargo test` before considering a change complete.
- Prefer borrowing (`&T`) over cloning unless ownership transfer is required.
- Keep `unwrap()` and `expect()` out of library code; they are acceptable only in tests and short-lived scripts.
