# Contributing to GhostType

Thank you for your interest in contributing to GhostType!

## Security Rules (Required)

- Never commit API keys, tokens, certificates, provisioning files, or private keys.
- Never commit local Xcode user files (`xcuserdata`) or local build artifacts.
- Keep all secrets in local Keychain or local environment files ignored by git.

## Local Setup

1. Install git hooks:

```bash
git config core.hooksPath .githooks
```

2. Run repository safety scan manually:

```bash
bash scripts/repo_safety_scan.sh
```

3. Generate project and build:

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project GhostType.xcodeproj -scheme GhostType -configuration Debug -derivedDataPath ./.build CODE_SIGNING_ALLOWED=NO build
```

4. Run tests:

```bash
xcodebuild -project GhostType.xcodeproj -scheme GhostType -configuration Debug -derivedDataPath ./.build test
```

## Hooks

- `.githooks/pre-commit` runs `scripts/repo_safety_scan.sh`
- `.githooks/pre-push` runs `scripts/repo_safety_scan.sh`

## Keychain Behavior

- Startup must not read Keychain automatically.
- Keychain access must be user-action driven only (for example, cloud run, test connection, or credential maintenance buttons).
- Legacy credential migration must be user-triggered from settings.

## Prompt Engineering Help Wanted

GhostType ships with a V1.0 set of system prompts for dictation, ask, and translate workflows. These prompts work, but there is significant room for improvement.

**We especially welcome contributions that:**

- Improve transcription accuracy for domain-specific vocabulary (medical, legal, engineering, etc.)
- Reduce hallucination in the LLM rewrite step
- Better preserve the speaker's intent and tone
- Improve multilingual support (especially CJK languages)
- Add new prompt presets for specific use cases (email drafting, code comments, meeting notes, etc.)

**How to contribute prompt improvements:**

1. Open an Issue describing the scenario and the current vs. expected output.
2. Include example transcripts (before/after) so we can evaluate the change.
3. If you have a working prompt, submit it as a PR modifying `different_prompt_typeless.md`.

All prompt contributions will be reviewed and tested before merging.

## Code Contributions

1. Fork the repository and create a feature branch.
2. Make your changes, ensuring all tests pass.
3. Run the safety scan: `bash scripts/repo_safety_scan.sh`
4. Submit a Pull Request with a clear description of the change.

## Reporting Issues

- Use the GitHub Issues tab for bug reports and feature requests.
- For security vulnerabilities, see `SECURITY.md`.

## A Note on AI-Assisted Development

This project was built with significant AI assistance (Claude, GPT). I'm a student, not a 10x SwiftUI wizard — AI helped me ship faster and tackle unfamiliar domains (audio processing, Accessibility API, MLX integration).

The development thought process, prompt strategies, and iteration logs are archived in [`docs/dev-notes/`](docs/dev-notes/) for anyone curious about how the project was built. If you're learning AI-assisted development, they might be useful reference material.

The code works. The architecture is sound. But some modules could always be cleaner — PRs welcome.
