# Editor navigation and selection

## Scope

Resolve item 7 of the local improvements list in the source editor, including source shown beside a preview.

- Arrow-key movement and selection keep the insertion point or active selection end within the unobscured text area. Use the live line-number gutter width and preserve the existing vertical layout and multicursor reveal behavior.
- Home and End move to the beginning and end of the physical line. Shift extends from the existing anchor. Command–Left and Command–Right retain visual-row navigation and smart indentation. Command–Up and Command–Down reach the start and end of the document.
- Focused and unfocused selections use an editor palette with readable text and a visible fill. Require at least 4.5:1 contrast for base text and syntax colors, including comments, across all 18 bundled themes.

## Adversarial design review

Astra challenged the initial approach with mixed LF/CRLF, the empty row after a final newline, an unterminated row ending in a composed character, repeated movement at a wrap boundary, and Shift movement that reverses direction. The agreed design uses each row's real content boundary and the existing selection engine. At a soft wrap, the insertion point must retain the appropriate visual edge, and vertical navigation must start from the edge that was drawn. The implementation review added Unicode line separators, RTL insertion edges and preserving native input handling while an IME has marked text.

The review also identified a second scrolling path for the newest cursor and a live theme update that sets the selection color on the current-line highlight. The agreed approach shares gutter-aware reveal geometry while preserving cursor choice, and applies the selection palette to the source editor on both initial load and live theme changes.

## Validation

- Exercise key events and assert ranges and visible caret positions in a hosted editor, with line wrapping on and off, including Shift and multiple cursors.
- Check focused and unfocused palette combinations and live theme updates in the hosted editor.
- Build the signed app, run the macOS suite, and check the editing flow against the isolated Herdr session.
