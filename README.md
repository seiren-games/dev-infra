# dev-infra
Development shared files

## Rust Development Environment

Rust development tools are packaged through Nix:

```sh
nix profile install github:seiren-games/dev-infra#rust-dev-environment
```

The package is built from `rust/nix/modules/dev-environment.nix`. Repositories
that need to customize the tool list can import
`inputs.dev-infra.lib.rustDevEnvironmentModule` and override
`devInfra.rust.devEnvironment.packages`.

## Secret scanning

This repository provides Git hooks that block commits and pushes when gitleaks
detects secrets, personal information patterns, or confidentiality markers.
Commits also run a Codex CLI review of staged changes using the
`review-public-ok` skill and fail when the review finds information that should
not be published.

The gitleaks scanner is provided declaratively through Nix:

```sh
nix develop
```

The Codex review requires `codex` to be installed and available on `PATH`, and
uses `$HOME/dotfiles/home/.agents/skills/review-public-ok/SKILL.md` by default.
Set `CODEX_BIN` to use a specific Codex executable, or `PUBLIC_OK_SKILL_PATH`
to override the skill path.

Enable the versioned hooks once per clone:

```sh
git config core.hooksPath .githooks
```

After that, `git commit` scans staged changes and `git push` scans outgoing
commits. To run the commit-time scan manually:

```sh
scripts/secret-scan pre-commit
```

To run the full gitleaks history scan manually:

```sh
scripts/secret-scan all
```
