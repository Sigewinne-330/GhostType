# Open Source Security Setup

This document explains how to enable GitHub secret scanning and push protection for GhostType.

## 1. Repository Settings

1. Open repository `Settings`.
2. Go to `Security` or `Code security and analysis`.
3. Enable:
   - `Secret scanning`
   - `Push protection`

For public repositories, GitHub scans supported secret patterns in public content. Enabling push protection blocks pushes when supported secret patterns are detected.

## 2. Required Local Guardrail

Run the repository safety scan locally before pushing:

```bash
bash scripts/repo_safety_scan.sh
```

Install hooks so the scan runs automatically:

```bash
git config core.hooksPath .githooks
```

## 3. What Is Blocked

- Secret-like patterns: OpenAI key, Google key, AWS key, GitHub token, private key headers, certificate markers.
- Forbidden tracked files: `xcuserdata`, `DerivedData`, `.build`, `build`, `dist`, cert/key/provisioning file types.
- Oversized tracked files above `50 MB` (configurable with `REPO_SAFETY_MAX_FILE_MB`).

## 4. Non-git Directory Behavior

When run outside a git repository, scan exits successfully by default and prints guidance:

- Default: `REPO_SAFETY_NON_GIT_EXIT_CODE=0`
- Strict mode: set `REPO_SAFETY_NON_GIT_EXIT_CODE=1`

## 5. Incident Response

If a secret is exposed:

1. Revoke/rotate the secret immediately.
2. Remove it from repository history.
3. Re-run `scripts/repo_safety_scan.sh`.
4. Notify maintainers through the process in `SECURITY.md`.

