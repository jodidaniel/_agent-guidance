# AGENTS.md

> **Managed by [`_agent-guidance`].**
> Edit only below the `## Repo-specific additions` header.
> Everything above it will be overwritten on the next sync.

## General guidelines

- Read existing code before modifying it. Understand the patterns already in use.
- Keep changes minimal and focused — fix what was asked, nothing more.
- Do not add speculative features, premature abstractions, or unused helpers.
- Prefer editing existing files over creating new ones.
- Never commit secrets, credentials, or .env files.

## Code quality

- Follow the idioms and style already established in this repo.
- Write code that is clear enough to not need comments; add comments only when intent is non-obvious.
- Avoid introducing new dependencies unless strictly necessary.
- Every public interface change should include corresponding test updates.

## Security

- Validate all external input (user input, API responses, file contents).
- Never construct SQL, shell commands, or HTML by string concatenation with untrusted data.
- Use parameterized queries, shell arrays, and context-aware escaping respectively.
- Do not disable TLS verification, authentication, or CSRF protection.

## Testing

- Run the existing test suite before considering a task complete.
- New behavior requires new tests; bug fixes require regression tests.
- Tests should be deterministic — no sleeping, no network calls, no reliance on wall-clock time.

## Git practices

- Write concise commit messages that explain *why*, not just *what*.
- One logical change per commit.
- Do not amend published commits or force-push shared branches.
