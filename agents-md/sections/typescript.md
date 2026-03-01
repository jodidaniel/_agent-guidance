## TypeScript

- Do not use `any`. Use `unknown` and narrow with type guards when the type is genuinely uncertain.
- Prefer `interface` for object shapes that may be extended; use `type` for unions and intersections.
- Enable and respect the project's `tsconfig.json` strict settings.
- Use `as const` assertions instead of type casts where possible.
- Co-locate types with the code that uses them; export types only when consumed externally.
- Ensure generic functions have meaningful constraint bounds, not unbounded `<T>`.
