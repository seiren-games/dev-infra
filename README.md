# dev-infra
Development shared files

## Secret scanning

This repository provides Git hooks that block commits and pushes when gitleaks
detects secrets, personal information patterns, or confidentiality markers.

The scanner is provided declaratively through Nix:

```sh
nix develop
```

Enable the versioned hooks once per clone:

```sh
git config core.hooksPath .githooks
```

After that, `git commit` scans staged changes and `git push` scans outgoing
commits. To run the same scan manually:

```sh
scripts/secret-scan all
```
