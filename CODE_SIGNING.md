# Code signing policy

> [!NOTE]
> This policy describes the **upstream** LocalSend release pipeline. This fork inherits it unchanged and does not produce signed builds itself; local builds are unsigned.

Free code signing provided by [SignPath.io](https://signpath.io/), certificate by [SignPath Foundation](https://signpath.org/).

Official Windows release artifacts (portable ZIP, EXE installer, MSIX helper) of the upstream project are built automatically from the source code in the [upstream repository](https://github.com/localsend/localsend) using GitHub Actions ([release workflow](.github/workflows/release.yml)) and signed through SignPath. Every signing request is manually approved by an approver listed below.

Only binaries built by LocalChat are signed. Third-party binaries that are packaged with the app are distributed as provided by their upstream projects and do not receive the LocalChat signing operation.

Signed Windows files show **SignPath Foundation** as the publisher because the certificate belongs to the foundation, not to the LocalChat project.

## Team roles

- Committers and reviewers: [@Tienisto](https://github.com/Tienisto)
- Approvers: [@Tienisto](https://github.com/Tienisto)

## Privacy

LocalChat's privacy policy is available at [localsend.org/privacy](https://localsend.org/privacy).
