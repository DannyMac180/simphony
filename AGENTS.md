# Symphony

## PR Description Requirements

PR bodies must follow `.github/pull_request_template.md` exactly. The CI check
`validate-pr-description` requires these headings, in this order:

- `#### Context`
- `#### TL;DR`
- `#### Summary`
- `#### Alternatives`
- `#### Test Plan`

Before opening or updating a PR, write the body with those headings, remove all
template placeholder comments, include at least one bullet under `Summary` and
`Alternatives`, and include at least one checkbox under `Test Plan`.

Validate locally from `elixir/` when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Repository Notes

- The Elixir implementation lives in `elixir/`; follow `elixir/AGENTS.md` for
  code, test, and runtime conventions in that subtree.
- Keep root documentation changes in `README.md` aligned with implementation
  details in `elixir/README.md` when behavior changes.
