# CodeEdit editor packages

These packages are copies of the upstream `Sources/` trees, with their MIT licenses:

| Package | Version | Upstream commit |
| --- | --- | --- |
| [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor) | 0.9.1 | `b0688fa59fb8060840fb013afb4d6e6a96000f14` |
| [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) | 0.7.7 | `509d7b2e86460e8ec15b0dd5410cbc8e8c05940f` |

Their source files are unchanged. The local `Package.swift` files keep the runtime dependencies and omit test targets and SwiftLint build plugins. Those plugins download a separate binary and are unnecessary when building xherdr. Update the versions together after checking the editor API and running an xherdr build.
