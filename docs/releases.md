# Releases

A push to `main` builds and publishes a GitHub prerelease tagged `beta-<build>`.
Push a numeric version tag (`2.13.0` or `v2.13.0`) on a commit in `main` to publish
stable. The tag must advance the previous published stable version and build.
Do not use both tag spellings for the same version.

Both channels use `1000 + git rev-list --count <commit>`, including merged commits.
Keep full history and do not rewrite `main` or change the offset after publishing.
A beta and stable release of the same commit have equal build numbers. Sparkle
will not upgrade between them; users who disable beta wait for a higher stable
build. Every push builds its tip, rather than separately building every commit
included in that push.

Beta builds display `Beta (build)` in settings, with `Beta` as the update's display
version in Sparkle. Their internal marketing version stays numeric. Stable
versions come from the tag. Version overrides are confined to CI.

## One-time setup

1. Deploy the companion website changes in `~/code/Input-Source-Pro` first. Its
   `GITHUB_TOKEN` must be able to read this repository's releases. Existing
   public appcasts remain available through the legacy fallback until the first
   automated releases appear.
2. Export the **existing** Sparkle private key and store the exported base64 text
   as the repository Actions secret `SPARKLE_PRIVATE_KEY`. Do not generate a new
   production key. The workflow verifies each signature against the public key
   already embedded in `Info.plist`.
3. Retain the existing Actions secrets: `APPLE_DEVELOPMENT`,
   `APPLE_DEVELOPMENT_PSW`, `DEVELOPER_ID_APPLICATION`,
   `DEVELOPER_ID_APPLICATION_PSW`, `EXPORT_OPTIONS_PLIST_B64`,
   `KEYCHAIN_PASSWORD`, `APPLE_ID`, `NOTARY_PASSWORD`, and `TEAM_ID`.
   The workflow needs `contents: write` and the existing `xcode-27` runner.
4. Push the implementation to `main`. Verify the first beta through
   `https://inputsource.pro/beta/appcast.xml` and `/beta/download`, including an
   actual Sparkle update from the previous installed build, before tagging stable.

Never paste private keys into logs or commit them. The workflow puts credentials
in a temporary directory with restricted permissions and restores the runner's
keychain search list during cleanup.

## Publication and recovery

CI tests the app and release scripts, archives and exports the app, creates and
notarizes the DMG, staples it, and then generates the Sparkle feed using the pinned
Sparkle tools. No incremental delta archives are generated.

Each release contains `Input-Source-Pro-<build>.dmg` and `appcast.xml`. The feed
uses a version-specific `inputsource.pro/releases/<tag>/<asset>` download URL.
CI uploads to a draft, checks GitHub's asset hashes, then publishes. A failed run
can be rerun to resume the draft. Completed releases are never overwritten.
If a newer stable release overtakes an older build, the older draft is left
unpublished and the run fails.

Stable releases use `docs/release-notes/<version>.md` when that file exists in
the release commit. Both `2.13.0` and `v2.13.0` tags use `2.13.0.md`. The Markdown
becomes the GitHub release body, and GitHub's Markdown API renders the same text
as HTML for Sparkle. The existing workflow token and `gh` CLI handle rendering;
no additional dependency is needed. Empty files and rendering failures stop the
release rather than replacing custom notes with a commit list.

To prepare custom notes:

1. Review changes since the preceding published stable release and send a draft
   changelog in chat. Include user-facing changes, verified contributor credits,
   and relevant pull request links, following the 2.12.0 release style.
2. Let the user review and approve the wording before saving the release notes,
   updating the website changelog, or publishing the release.
3. Save the approved Markdown in `docs/release-notes/<version>.md` and commit it
   with the release changes before tagging. Uncommitted edits are not used.

If the version's file is absent, stable notes contain non-merge commit subjects
since the preceding published stable tag, initially `2.12.0`. Beta tags do not
reset that range. Commit text is escaped for both HTML and Markdown. Beta notes
always link to the repository, even when custom stable notes exist. Completed
releases keep their original notes on reruns.

The website selects the highest eligible build, not the most recently completed
workflow. Beta accepts newer stable builds and prefers stable on a tie. Drafts
and incomplete releases are ignored. A GitHub outage produces a retryable 503;
it does not silently redirect to another release.

## Local checks

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_*.py'
xcodebuild -scheme "Input Source Pro" -configuration Debug test
```

The website also has `npm run test:releases`. Run its TypeScript check and normal
Cloudflare build before deployment. Local tests cannot validate Apple credentials,
notarization, production redirects, or a real installed-app update; verify those
with the first beta before publishing stable.
