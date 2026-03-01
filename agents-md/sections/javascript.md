## JavaScript

- Use `const` by default; use `let` only when reassignment is necessary; never use `var`.
- Use strict equality (`===` / `!==`).
- Prefer `async`/`await` over raw Promise chains.
- Handle errors in every `catch` block — never swallow exceptions silently.
- Use the project's existing module system (ESM or CommonJS) consistently.
- Do not introduce global variables or modify built-in prototypes.
- Run the linter (`eslint`, `biome`, etc.) before considering a change complete.
