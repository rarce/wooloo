#!/usr/bin/env python3
"""Writes Vendor/Herdr/NOTICES.txt: the licenses of the code built into the Herdr helper.

    scripts/herdr-notices.py <herdr checkout>

The checkout must be at the tag that scripts/bundle-herdr.sh downloads. It needs
cargo: the Rust crates are those the macOS binaries link (normal and build
dependencies of both Apple targets, from Cargo.lock), with their license files
from the cargo registry, or from their GitHub repository when the crate omits
them (set GITHUB_TOKEN to raise the rate limit). Ghostty's terminal library is
built from the checkout's vendor/libghostty-vt, and its native dependencies are
downloaded from the URLs its build.zig.zon files pin. Run scripts/third-party-notices.py afterwards.
"""

import base64
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Vendor/Herdr/NOTICES.txt"
TARGETS = ["aarch64-apple-darwin", "x86_64-apple-darwin"]

# Native code that libghostty-vt compiles in with Herdr's build options (SIMD on,
# Kitty graphics on): (name, url, archive or file to read, license file patterns).
GHOSTTY_ZON = "vendor/libghostty-vt/build.zig.zon"
NATIVE = [
    ("uucode", "https://github.com/jacobsandlund/uucode", GHOSTTY_ZON, "uucode",
     ["LICENSE.md", "licenses/LICENSE_Bjoern_Hoehrmann", "licenses/LICENSE_unicode"]),
    ("Highway", "https://github.com/google/highway", "vendor/libghostty-vt/pkg/highway/build.zig.zon",
     "highway", ["LICENSE", "LICENSE-BSD3"]),
    ("Wuffs", "https://github.com/google/wuffs", "vendor/libghostty-vt/pkg/wuffs/build.zig.zon",
     "wuffs", ["LICENSE-APACHE"]),
]
SIMDUTF_HEADER = "vendor/libghostty-vt/pkg/simdutf/vendor/simdutf.h"

# License families recognized from a file's text, most specific first.
FAMILIES = [
    ("Apache-2.0", r"Apache License"),
    ("BSL-1.0", r"Boost Software License"),
    ("Unicode", r"UNICODE LICENSE|Unicode, Inc\."),
    ("Unlicense", r"unlicense\.org"),
    ("WTFPL", r"DO WHAT THE FUCK"),
    ("0BSD", r"Permission to use, copy, modify, and/or distribute this software for any"),
    ("MIT", r"Permission is hereby granted, free of charge"),
    ("BSD", r"Redistribution and use in source and binary forms"),
    ("Zlib", r"This software is provided ['‘]as-is['’]"),
]
# Which family to reproduce when a crate offers a choice.
PREFERENCE = ["MIT", "Apache-2.0", "BSD", "Zlib", "0BSD", "BSL-1.0", "Unlicense", "WTFPL"]
LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|UNLICENSE)", re.I)


def families(text):
    return {name for name, pattern in FAMILIES if re.search(pattern, text, re.I)}


def spdx_family(spdx):
    if spdx.startswith("Unicode"):
        return "Unicode"
    if spdx.startswith("BSD"):
        return "BSD"
    return spdx.split(" WITH ")[0]


def chosen_families(expression):
    """The families to reproduce: every part of an AND, the preferred option of an OR."""
    parts = re.split(r"\s+AND\s+", expression.replace("/", " OR "))
    chosen = []
    for part in parts:
        options = {spdx_family(o.strip(" ()")) for o in re.split(r"\s+OR\s+", part.strip(" ()"))}
        chosen.append(sorted(options, key=lambda f: PREFERENCE.index(f) if f in PREFERENCE else 99))
    return chosen


def crates(checkout):
    packages, shipped = {}, set()
    for target in TARGETS:
        metadata = json.loads(subprocess.run(
            ["cargo", "metadata", "--locked", "--format-version", "1", "--filter-platform", target],
            cwd=checkout, check=True, capture_output=True, text=True).stdout)
        packages.update({p["id"]: p for p in metadata["packages"]})
        nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}
        stack = [metadata["resolve"]["root"]]
        while stack:
            node = stack.pop()
            if node not in shipped:
                shipped.add(node)
                stack += [d["pkg"] for d in nodes[node]["deps"]
                          if any(k["kind"] in (None, "build") for k in d["dep_kinds"])]
    workspace = {p["id"] for p in packages.values() if p["source"] is None and p["name"] != "portable-pty"}
    return sorted((packages[i] for i in shipped - workspace), key=lambda p: (p["name"].lower(), p["version"]))


def crate_texts(package):
    directory = Path(package["manifest_path"]).parent
    files = [f for f in sorted(directory.iterdir()) if f.is_file() and LICENSE_FILE.match(f.name)]
    texts = [(f.read_text(errors="replace").strip(), f) for f in files]
    if not texts and (repo := re.match(r"https://github\.com/([^/]+/[^/.]+)", package.get("repository") or "")):
        # Some crates are published without their license files; use the repository's.
        texts = [(text, None) for text in github_licenses(repo.group(1))]
    found = {name: text for text, _ in reversed(texts) for name in families(text)}
    picked = []
    for options in chosen_families(package["license"] or ""):
        match = next((found[f] for f in options if f in found), None)
        if match is None:
            return None
        picked.append(match)
    picked += [text for text, f in texts if f and f.name.upper().startswith("NOTICE")]
    return list(dict.fromkeys(picked))


def github_licenses(repo):
    """The license files at the root of a GitHub repository's default branch."""
    def get(url):
        request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
        if token := os.environ.get("GITHUB_TOKEN"):
            request.add_header("Authorization", f"Bearer {token}")
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    return [base64.b64decode(get(entry["url"])["content"]).decode().strip()
            for entry in get(f"https://api.github.com/repos/{repo}/contents")
            if entry["type"] == "file" and LICENSE_FILE.match(entry["name"])]


def zon_url(zon, name):
    block = re.search(rf"\.{name}\s*=\s*\.\{{(.*?)\}}", zon, re.S).group(1)
    return re.search(r'\.url\s*=\s*"([^"]+)"', block).group(1)


def archive_texts(url, names):
    # deps.files.ghostty.org refuses Python's default user agent.
    request = urllib.request.Request(url, headers={"User-Agent": "wooloo-notices"})
    with urllib.request.urlopen(request, timeout=60) as response:
        archive = tarfile.open(fileobj=io.BytesIO(response.read()), mode="r:*")
    members = {m.name.split("/", 1)[1]: m for m in archive.getmembers() if "/" in m.name and m.isfile()}
    return [archive.extractfile(members[n]).read().decode().strip() for n in names]


def rule(title, char="="):
    return f"\n{char * 78}\n{title}\n{char * 78}\n\n"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    checkout = Path(sys.argv[1]).resolve()
    subprocess.run(["cargo", "fetch", "--locked", "--quiet"], cwd=checkout, check=True)

    groups, missing = {}, []
    for package in crates(checkout):
        label = f"{package['name']} {package['version']} ({package['license']})"
        texts = crate_texts(package)
        if texts is None:
            missing.append(label)
        else:
            groups.setdefault("\n\n".join(texts), []).append(label)
    if missing:
        sys.exit("No license file for the chosen license of:\n  " + "\n  ".join(missing))

    out = ["The Herdr helper is built from Herdr's source with Ghostty's terminal library and\n",
           "the Rust crates and native libraries below, under their own licenses.\n"]
    out += [rule("Ghostty (libghostty-vt)\nhttps://github.com/ghostty-org/ghostty", "-"),
            (checkout / "vendor/libghostty-vt/LICENSE").read_text().strip() + "\n"]
    version = re.search(r'#define SIMDUTF_VERSION "([^"]+)"', (checkout / SIMDUTF_HEADER).read_text()).group(1)
    simdutf = urllib.request.urlopen(
        f"https://raw.githubusercontent.com/simdutf/simdutf/v{version}/LICENSE-MIT", timeout=60).read().decode()
    out += [rule(f"simdutf {version}\nhttps://github.com/simdutf/simdutf", "-"), simdutf.strip() + "\n"]
    for name, url, zon, dependency, files in NATIVE:
        texts = archive_texts(zon_url((checkout / zon).read_text(), dependency), files)
        out += [rule(f"{name}\n{url}", "-"), "\n\n".join(texts) + "\n"]

    for text, labels in sorted(groups.items(), key=lambda g: g[1][0].lower()):
        out += [rule("Rust crates: " + ", ".join(labels).replace(", ", "\n             "), "-"), text + "\n"]

    OUTPUT.write_text("".join(out))
    print(f"Wrote {OUTPUT.relative_to(ROOT)}: {sum(map(len, groups.values()))} crates, {len(groups)} license texts")


if __name__ == "__main__":
    main()
