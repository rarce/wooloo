# File syntax

The document header shows `Auto: <language>` when automatic detection is active, or the
chosen language when a document has a manual override. Click it to search the available
syntaxes, choose Plain Text, or return to automatic detection. A manual choice stays with
the document across tab switches, session restoration and saving a draft.

**File Associations…** in the selector creates and removes persistent, app-wide rules.
Saving a rule returns the current document to Auto. A pattern without `/` matches a
filename; a pattern with `/` matches the workspace-relative path. Supported wildcards:

- `*`: zero or more characters within one path component.
- `?`: one character within one path component.
- `**`: zero or more characters across directories; `**/` also matches zero directories.

For example, `*.conf` selects all configuration files, `nginx.conf` selects a particular
filename, and `config/**/*.conf` selects configuration files below `config/`. Matching is
case-sensitive. Rules with more literal characters take priority; the most recently saved
rule breaks ties. Saving the same pattern replaces its existing association. Remove a rule
to restore built-in detection. Unknown syntax identifiers in saved preferences are ignored.

Resolution is shared by source editors and diffs: manual override, matching association,
then built-in detection. INI files use INI; `.conf`, `.cfg`, `.properties`, `.directory`,
`.repo` and common Git/EditorConfig configuration names use Properties. Notebooks default
to JSON. Other files use CodeEditLanguages' filename/extension, shebang and Vim/Emacs
modeline detection, falling back to Plain Text. Diff detection uses the whole new file,
or the old file for deletions, rather than the patch text.

INI and Properties share a line-oriented colorizer for sections, keys, quoted and unquoted
values, numbers, booleans and comments. It does not validate a configuration format or
provide specialized Nginx/SSH syntax. Other syntaxes use Tree-sitter. The picker omits
Agda, Julia, Perl and Verilog because the pinned language package has no highlighting
queries for them. Markdown rendering and notebook previews retain their existing behavior.
