# Conventional Commits, the short version

```
<type>(<scope>): <summary>

<body: the why, wrapped at 72>

<footer: BREAKING CHANGE: ..., Refs: #123, Signed-off-by: ...>
```

Types: `feat` (a feature), `fix` (a bug), `docs`, `test`, `refactor` (no behaviour change),
`perf`, `build`, `ci`, `chore`. A `!` after the type or scope marks a breaking change.

Summary: imperative ("add", not "added"), no trailing period, under 72 characters. Scope: the
module, package or area, in parentheses, optional.
