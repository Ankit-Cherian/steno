# Activating Steno's GitHub pipeline

The repository files define the jobs. GitHub settings enforce who can merge, access signing credentials, and publish. Complete this setup before relying on the gates. These instructions do not assert that the settings have already been applied.

## 1. Integrate and observe the workflows

Review the change, integrate it into the intended default branch, and observe a complete successful CI and Security run on that exact source. Confirm a fork PR can run without secrets and that a deliberately failing check blocks its gate. Do not enable required check names before GitHub has observed them.

Use the **Checks** UI or the check-runs API to obtain the actual check names, including any reusable-workflow prefix:

```bash
gh api --paginate repos/Ankit-Cherian/steno/commits/main/check-runs \
  --jq '.check_runs[] | {name,conclusion,app:.app.slug,details_url}'
```

Select the checks corresponding to `CI Gate` and `Security Gate`, produced by **GitHub Actions**. The reusable validation workflow currently reports `validate / CI Gate`; the security workflow reports `Security Gate`. Verify these names from a real run before applying them. Do not substitute a similarly named check from another integration. Confirm branch protection against an actual test PR; configuration presence alone is not enforcement proof.

## 2. Enforce main's checks

Create an active **branch ruleset** for the default branch with:

- Both observed aggregate checks required, restricted to the GitHub Actions integration.
- Branches up to date before merging.
- No bypass actors for these check requirements, including the maintainer.
- Block force pushes and branch deletion.

Inspect and preserve any existing review, conversation-resolution, and linear-history protections; configure the intended policy if it is absent. Require code-owner review for outside contributions to the sensitive paths in `.github/CODEOWNERS`.

For a sole maintainer, keep review policy separate from the required-check ruleset: the maintainer may need a review-policy bypass for their own contribution because GitHub does not permit self-approval of a PR. That exception must not bypass CI or security checks. Once there is another trusted maintainer, require independent review for maintainer changes as well. A protection that nobody can satisfy is not a useful release process.

If classic branch protection already requires a review, it also applies alongside the ruleset. Check both surfaces when configuring a maintainer exception; a bypass on one review rule does not remove another rule's requirement. Preserve the separate required-check protection throughout any migration.

Verify that a tag ruleset protects `v*` tags against updates and deletion, preserving any existing protection. Enable immutable releases if available, after reviewing its irreversible effects; attach all intended assets before publishing. Do not rewrite existing release tags.

## 3. Harden repository automation

In **Settings → Actions → General**:

- Keep the default workflow token read-only.
- Keep workflow PR creation/approval disabled.
- Require approval for workflow runs from **all external contributors**.
- Require full-length SHA pins for Actions.
- Allow only the reviewed Action owners/actions used by this repository: `actions/checkout`, `actions/upload-artifact`, `actions/download-artifact`, `actions/dependency-review-action`, `actions/attest`, and `github/codeql-action/*`. Recheck the list when workflows change.
- Use GitHub-hosted runners. Do not connect the maintainer's personal Mac as a runner for untrusted PRs.

In **Settings → Code security**:

- Enable the dependency graph, Dependabot alerts, and Dependabot security updates.
- Enable secret scanning and push protection. Inspect existing alerts privately; do not paste secret values into an issue or a CI log.
- Enable private vulnerability reporting if it is not already available.
- Use the checked-in **advanced CodeQL workflow**. Do not also enable default CodeQL setup for the same languages, which would duplicate/conflict with advanced setup.

The dependency graph covers supported dependency manifests. It does not replace review of the manually pinned C++ runtime or model files.

## 4. Create protected release environments

Create these exact environments, restrict deployment branches to **main**, and require approval by the maintainer or a designated release reviewer:

| Environment | Enablement variable | Secrets |
| --- | --- | --- |
| `release` | `RELEASE_ENABLED=true` | Apple signing/notary secrets listed below |
| `release-draft` | `RELEASE_DRAFT_ENABLED=true` | None |
| `release-publish` | `RELEASE_PUBLISH_ENABLED=true` | None |

Keep variables unset until reviewers and branch restrictions are verified. Disable administrator bypass of deployment protections where supported. With only one maintainer, **do not enable Prevent self-review**: the maintainer must be able to approve a deployment they dispatched. With a second release maintainer, enabling it gives independent approval.

Environment names and variables are not proof of protection. Inspect each environment's required reviewer, branch policy, and bypass settings, then test an approval pause before adding credentials. A missing environment can otherwise be created by a workflow without the intended protections.

## 5. Add Apple credentials in the trusted UI

A Developer ID Application certificate/private key and a valid App Store Connect notary API key are external prerequisites. Creating or exporting them requires the maintainer's account access. Never commit them or place them in repository-wide Actions secrets. Enter them only as **environment secrets under `release`**:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64 of the exported Developer ID Application certificate and private key (`.p12`), as one line |
| `APPLE_CERTIFICATE_PASSWORD` | Export password for that `.p12` |
| `APPLE_SIGNING_IDENTITY` | Exact `Developer ID Application: … (TEAMID)` identity |
| `APPLE_TEAM_ID` | Corresponding 10-character Apple team identifier |
| `APPLE_NOTARY_KEY_P8_BASE64` | One-line base64 of the notary API private key |
| `APPLE_NOTARY_KEY_ID` | API key identifier |
| `APPLE_NOTARY_ISSUER_ID` | API issuer UUID |

Use a dedicated, least-privileged credential suitable for notarization. Review its scope in Apple's trusted UI. The workflow imports the certificate into a temporary keychain, never changes the runner's default keychain, and removes temporary signing material after the step. Rotate/revoke credentials when ownership or access changes.

## 6. Prove activation

Record the source SHA and links to these results:

- A successful first full CI run and Security run.
- An external PR run without credential access.
- A failed-check PR that cannot merge under the new rules.
- A release approval pause that cannot be bypassed through an unprotected branch.
- A successful signed/notarized draft with matching tag, source, final DMG hash and attestation, once release acceptance is approved.
- A separately approved publication with verified release ID, unchanged uploaded asset digests, and the same release at `/releases/latest`.

A draft is not a public release. A signed build is not proof of notarization. A green local check is not proof of a hosted workflow. Keep the [release checklist](../release/1.0-checklist.md) and [operating guide](../ci-cd.md) with the actual run receipts.

GitHub's [environment protection documentation](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments), [ruleset documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets), and [Apple signing setup guide](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications) describe the corresponding platform controls.
