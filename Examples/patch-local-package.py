#!/usr/bin/env python3
"""Re-apply the local-package fix after `xcodegen generate`.

XcodeGen 2.33 emits the local VoltaSDK package as a legacy folder reference,
which Xcode 27 rejects ("Missing package product"). This script rewrites the
generated project to the modern form: an `XCLocalSwiftPackageReference`
(relativePath ../..) listed under the project's `packageReferences`, with
every `XCSwiftPackageProductDependency` pointing at it.

Usage (from the demo directory, after xcodegen):
    python3 ../patch-local-package.py macOSDemo.xcodeproj/project.pbxproj
    python3 ../patch-local-package.py iOSDemo.xcodeproj/project.pbxproj --entitlements iOSDemo.entitlements

`--entitlements` additionally sets CODE_SIGN_ENTITLEMENTS on the APP target's
build configurations (the PCC opt-in). That change is meant to stay
uncommitted: the committed projects are entitlement-free by policy.
"""

import re
import sys

PACKAGE_REF_ID = "B2C3D4E5F6071829A0B1C2D3"


def patch(text, entitlements):
    text = text.replace("objectVersion = 51;", "objectVersion = 60;")

    # 1. Drop the folder reference for `../..` and the Packages group.
    folder_ref = re.search(
        r"\t\t(\w+) /\* [^*]* \*/ = \{isa = PBXFileReference; lastKnownFileType = folder; [^\n]*path = \.\./\.\.; sourceTree = SOURCE_ROOT; \};\n",
        text,
    )
    if folder_ref:
        ref_id = folder_ref.group(1)
        text = text.replace(folder_ref.group(0), "")
        group = re.search(
            r"\t\t(\w+) /\* Packages \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n\t\t\t\t" + ref_id + r" /\* [^*]* \*/,\n\t\t\t\);\n\t\t\tname = Packages;\n\t\t\tsourceTree = SOURCE_ROOT;\n\t\t\};\n",
            text,
        )
        if group:
            group_id = group.group(1)
            text = text.replace(group.group(0), "")
            text = re.sub(r"\t\t\t\t" + group_id + r" /\* Packages \*/,\n", "", text)

    # 2. The project object lists the package reference.
    if "packageReferences" not in text:
        text = re.sub(
            r"(\t\t\tmainGroup = \w+;\n)",
            r"\1\t\t\tpackageReferences = (\n\t\t\t\t" + PACKAGE_REF_ID + r' /* XCLocalSwiftPackageReference "../.." */,\n\t\t\t);\n',
            text,
            count=1,
        )

    # 3. The XCLocalSwiftPackageReference section itself.
    if "XCLocalSwiftPackageReference section" not in text:
        section = (
            "/* Begin XCLocalSwiftPackageReference section */\n"
            f'\t\t{PACKAGE_REF_ID} /* XCLocalSwiftPackageReference "../.." */ = {{\n'
            "\t\t\tisa = XCLocalSwiftPackageReference;\n"
            "\t\t\trelativePath = ../..;\n"
            "\t\t};\n"
            "/* End XCLocalSwiftPackageReference section */\n\n"
        )
        text = text.replace("/* Begin XCSwiftPackageProductDependency section */", section + "/* Begin XCSwiftPackageProductDependency section */")

    # 4. Every product dependency points at the package.
    text = re.sub(
        r"(\t\t\tisa = XCSwiftPackageProductDependency;\n)(\t\t\tproductName = )",
        r"\1\t\t\tpackage = " + PACKAGE_REF_ID + r' /* XCLocalSwiftPackageReference "../.." */;\n\2',
        text,
    )

    # 5. Optional: PCC entitlement on the app target (local, uncommitted).
    if entitlements:
        text = re.sub(
            r"(\t\t\t\tDEVELOPMENT_TEAM = \w+;\n)(\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n\t\t\t\tINFOPLIST_KEY_LSApplicationCategoryType|\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n\t\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation)",
            r"\1\t\t\t\tCODE_SIGN_ENTITLEMENTS = " + entitlements + r";\n\2",
            text,
        )
    return text


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    path = sys.argv[1]
    entitlements = None
    if "--entitlements" in sys.argv:
        entitlements = sys.argv[sys.argv.index("--entitlements") + 1]
    with open(path) as handle:
        original = handle.read()
    patched = patch(original, entitlements)
    with open(path, "w") as handle:
        handle.write(patched)
    print("patched", path, "(entitlements: %s)" % (entitlements or "none"))


if __name__ == "__main__":
    main()
