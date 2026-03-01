## .NET / C#

- Use nullable reference types (`#nullable enable`) and resolve all warnings.
- Prefer `async Task` / `async ValueTask` for I/O-bound operations; do not block with `.Result` or `.Wait()`.
- Use dependency injection via the built-in container; avoid service-locator patterns.
- Follow framework naming conventions (PascalCase for public members, `_camelCase` for private fields).
- Dispose `IDisposable` resources with `using` statements or `using` declarations.
- Target the .NET version already in use in the project — do not upgrade without discussion.
- Run `dotnet build --warnaserror` and the existing test suite before completing a change.
