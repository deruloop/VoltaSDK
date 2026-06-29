# macOS demo

The signed macOS counterpart to [`Examples/iOSDemo`](../iOSDemo). It runs the
**same shared chat UI** (`VoltaSDKDemoUI`), so it shows the full provider chain,
the fallback behaviour, the privacy badges, and the model picker — plus
**Private Cloud Compute** on macOS 27.

> Why an Xcode app and not `swift run`: only a code-signed app can carry the
> PCC entitlement and exercise PCC live. The package no longer ships a
> `swift run` macOS demo — this signed app replaces it.

## Generate / open

```sh
cd Examples/macOSDemo
open macOSDemo.xcodeproj          # build with Xcode 27
```

Set the signing **Team** to your own (Signing & Capabilities, or
`DEVELOPMENT_TEAM` in `project.yml`).

> ⚠️ The committed `.xcodeproj` is hand-patched (modern
> `XCLocalSwiftPackageReference`). Don't blindly `xcodegen generate` — XcodeGen
> 2.33 reverts it to a folder reference that Xcode 27 rejects. If you
> regenerate, re-apply that fix (see `project.yml`).

## Private Cloud Compute (opt-in)

By default this demo builds and runs **without** PCC: the `private-cloud-compute`
row shows as *unavailable* and the chain falls back to on-device. **No
entitlement is required to build or run.**

To exercise **live** PCC:

1. Request the entitlement from Apple — see the
   [Private Cloud Compute section in the repo README](../../README.md). It is
   developer-side (App Store Small Business Program, < 2M downloads).
2. In Xcode: target **macOSDemo → Signing & Capabilities → + Capability →
   Private Cloud Compute** (or uncomment `CODE_SIGN_ENTITLEMENTS` in
   `project.yml` and re-run `xcodegen generate`).
3. Build & run on an Apple-Intelligence Mac (macOS 27). The `private-cloud-compute`
   row turns available and answers at privacy level `appleCloud`.
