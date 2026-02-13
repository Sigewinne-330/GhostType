## Summary

- [ ] Bug fix
- [ ] Refactor
- [ ] New feature
- [ ] Documentation
- [ ] CI / release tooling

Describe what changed and why.

## Validation

Run and paste results:

```bash
bash scripts/repo_safety_scan.sh
xcodegen generate
xcodebuild -project GhostType.xcodeproj -scheme GhostType -configuration Debug -derivedDataPath ./.build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project GhostType.xcodeproj -scheme GhostType -configuration Debug -derivedDataPath ./.build test
```

## Keychain / Credential Access Checklist

- [ ] I verified startup path does not read credentials.
- [ ] If this PR reads credentials, the access is user-action driven only.
- [ ] I did not include any real API key/token/certificate/private key in this PR.

## Safety Scan Checklist

- [ ] `scripts/repo_safety_scan.sh` passes locally.
- [ ] No `xcuserdata`, build artifacts, or provisioning/cert files are tracked.

## Notes

Additional context, screenshots, or follow-up tasks.
