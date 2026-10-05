# Notebook preview assets

These browser bundles are shipped with xherdr and run offline inside the restricted notebook webview. No CDN or Python runtime is used by the app.

| Component | Version | Purpose | License |
| --- | --- | --- | --- |
| markdown-it | 15.0.2 | Markdown cells and output | MIT |
| DOMPurify | 3.4.16 | HTML and SVG sanitization | Apache-2.0 OR MPL-2.0 |
| KaTeX | 0.19.0 | Math and local WOFF2 fonts | MIT |
| highlight.js CDN assets | 11.12.0 | Code highlighting | BSD-3-Clause |

`sources.json` records the official npm tarball URLs, SHA-512 npm integrity values, archive SHA-256 hashes, and shipped file lists. The original licenses are included in this directory and copied into the app bundle.

To update, download the pinned official npm archives to a temporary directory and verify their integrity before extracting:

- markdown-it: `package/dist/browser/markdown-it.umd.min.js` as `markdown-it.min.js`, plus `package/LICENSE`.
- DOMPurify: `package/dist/purify.min.js`, plus `package/LICENSE`.
- KaTeX: `package/dist/katex.min.js`, `package/dist/katex.min.css`, `package/dist/contrib/auto-render.min.js`, all `package/dist/fonts/*.woff2`, plus `package/LICENSE`.
- highlight.js CDN assets: `package/highlight.min.js`, plus `package/LICENSE`.

Retain the layout, update the manifest and notices, and run `NotebookRenderingTests`. Notebook-authored JavaScript is never passed to these bundles for execution. The application template and renderer are in `xherdr/NotebookAssets/`.
