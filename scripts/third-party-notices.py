#!/usr/bin/env python3
"""Writes THIRD_PARTY_NOTICES.txt from the licenses of every package xherdr ships.

    scripts/third-party-notices.py [checkouts]

`checkouts` is the SwiftPM checkout directory of a resolved build, by default
build/DerivedData/SourcePackages/checkouts. Run it after changing a dependency.
The grammars built into CodeEditLanguages' binary framework have no checkout, so
their licenses are fetched from GitHub; set GITHUB_TOKEN to raise the rate limit.
"""

import base64
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "THIRD_PARTY_NOTICES.txt"

# (name, url, license file) for packages copied into Vendor/.
VENDORED = [
    ("Herdr 0.9.3", "https://github.com/herdrdev/herdr/tree/v0.9.3", "Vendor/Herdr/LICENSE"),
    ("CodeEditSourceEditor", "https://github.com/CodeEditApp/CodeEditSourceEditor", "Vendor/CodeEditSourceEditor/LICENSE.md"),
    ("CodeEditTextView", "https://github.com/CodeEditApp/CodeEditTextView", "Vendor/CodeEditTextView/LICENSE.md"),
    ("MarkdownView", "https://github.com/LiYanan2004/MarkdownView", "Vendor/MarkdownView/LICENSE"),
    ("BeautifulMermaid", "https://github.com/lukilabs/beautiful-mermaid-swift", "Vendor/BeautifulMermaid/LICENSE"),
]

# (name, url, license files relative to the checkout) for packages resolved by SwiftPM.
RESOLVED = [
    ("elk-swift", "https://github.com/lukilabs/elk-swift", ["elk-swift/LICENSE"]),
    ("Highlightr", "https://github.com/raspu/Highlightr", ["Highlightr/LICENSE"]),
    ("highlight.js (bundled in Highlightr)", "https://github.com/highlightjs/highlight.js",
     ["Highlightr/src/assets/highlighter/LICENSE"]),
    ("RichText", "https://github.com/LiYanan2004/RichText", ["RichText/LICENSE"]),
    ("swift-markdown", "https://github.com/swiftlang/swift-markdown",
     ["swift-markdown/LICENSE.txt", "swift-markdown/NOTICE.txt"]),
    ("swift-cmark", "https://github.com/swiftlang/swift-cmark", ["swift-cmark/COPYING"]),
    ("swift-collections", "https://github.com/apple/swift-collections", ["swift-collections/LICENSE.txt"]),
    ("SwiftTreeSitter", "https://github.com/ChimeHQ/SwiftTreeSitter", ["SwiftTreeSitter/LICENSE"]),
    ("tree-sitter", "https://github.com/tree-sitter/tree-sitter", ["tree-sitter/LICENSE"]),
    ("TextFormation", "https://github.com/ChimeHQ/TextFormation", ["TextFormation/LICENSE"]),
    ("TextStory", "https://github.com/ChimeHQ/TextStory", ["TextStory/LICENSE"]),
    ("Rearrange", "https://github.com/ChimeHQ/Rearrange", ["Rearrange/LICENSE"]),
]

EPL_SOURCE = (
    "elk-swift is distributed under the Eclipse Public License 2.0. xherdr uses it\n"
    "unmodified. Its source code is available at https://github.com/lukilabs/elk-swift.\n"
)

CODEEDITLANGUAGES = (
    "CodeEditLanguages (https://github.com/CodeEditApp/CodeEditLanguages) packages the\n"
    "tree-sitter grammars below into a binary framework. The repository publishes no\n"
    "license file of its own; the grammars keep the licenses reproduced here.\n"
)


def rule(title):
    return f"\n{'=' * 78}\n{title}\n{'=' * 78}\n\n"


def github_license(repo):
    request = urllib.request.Request(f"https://api.github.com/repos/{repo}/license",
                                     headers={"Accept": "application/vnd.github+json"})
    if token := os.environ.get("GITHUB_TOKEN"):
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=20) as response:
        body = json.load(response)
    return body["license"]["spdx_id"], base64.b64decode(body["content"]).decode()


def grammar_repos(checkouts):
    project = checkouts / "CodeEditLanguages/CodeLanguages-Container/CodeLanguages-Container.xcodeproj/project.pbxproj"
    urls = re.findall(r'repositoryURL = "https://github.com/([^"]+?)(?:\.git)?"', project.read_text())
    return sorted(set(urls), key=str.lower)


def main():
    checkouts = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build/DerivedData/SourcePackages/checkouts")
    if not (checkouts / "CodeEditLanguages").is_dir():
        sys.exit(f"No resolved packages in {checkouts}; build xherdr first or pass the checkouts directory.")

    out = ["xherdr includes the following third-party software.\n",
           "xherdr itself is licensed under the MIT License; see LICENSE.\n"]
    for name, url, path in VENDORED:
        out += [rule(f"{name}\n{url}"), (ROOT / path).read_text().strip() + "\n"]
    for name, url, paths in RESOLVED:
        out.append(rule(f"{name}\n{url}"))
        if name == "elk-swift":
            out.append(EPL_SOURCE + "\n")
        out += [(checkouts / path).read_text().strip() + "\n\n" for path in paths]

    out.append(rule("Tree-sitter grammars (via CodeEditLanguages)"))
    out.append(CODEEDITLANGUAGES)
    for repo in grammar_repos(checkouts):
        spdx, text = github_license(repo)
        out += [f"\n{'-' * 78}\n{repo} ({spdx})\nhttps://github.com/{repo}\n{'-' * 78}\n\n", text.strip() + "\n"]

    OUTPUT.write_text("".join(out))
    print(f"Wrote {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
