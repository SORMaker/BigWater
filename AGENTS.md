# Repository instructions

## Commit messages

Use [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
for every commit in this repository:

```text
type(scope): description
```

- The scope is optional. When useful, name the affected area, such as `app`,
  `schedule`, `reminder`, `stats`, `storage`, `overlay`, `readme`, or `review`.
- Use lowercase types and scopes. Write a concise English description in the
  imperative, without a trailing period. Keep the subject within 72 characters.
- Choose the type from the purpose of the change:
  - `feat`: add a feature.
  - `fix`: correct existing behavior.
  - `docs`: change documentation or review records.
  - `refactor`: restructure code without changing external behavior.
  - `test`: change tests or test infrastructure.
  - `build`: change builds, packaging, or dependencies.
  - `ci`: change continuous integration or delivery workflows.
  - `perf`: improve performance.
  - `style`: change formatting without changing behavior.
  - `chore`: perform other maintenance, such as adding a license.
  - `revert`: revert a previous commit.
- Keep tests and documentation that support one feature or fix in that commit.
  Split changes with independent purposes into separate commits.
- Add a body when context, reasoning, or validation helps explain the change.
  Preserve existing authorship trailers when rewriting a commit message.
- Mark breaking changes with `!` after the type/scope or a `BREAKING CHANGE:`
  footer, as specified by Conventional Commits.

Example: `fix(stats): count character clicks as drink confirmations`.
