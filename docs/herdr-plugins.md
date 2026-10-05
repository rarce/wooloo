# Herdr plugin system and integration plan

## Scope

Herdr plugins are directories containing a `herdr-plugin.toml` manifest and executable commands. The server launches these commands for actions, startup hooks, lifecycle events, and terminal pane entrypoints. Plugins can use the same CLI and socket APIs as other clients. Herdr owns registration, invocation context, terminal processes, and command logs; each plugin owns its implementation, dependencies, configuration, and application state. See [Herdr plugins](https://herdr.dev/docs/plugins/) and [Plugin APIs](https://herdr.dev/docs/socket-api/#plugin-apis).

This research was checked on October 5, 2026 against the installed Herdr 0.9.3 binary and the [0.9.3 source commit](https://github.com/herdrdev/herdr/tree/7b116c05bfda646af39d2524c54e70c751f57ee8). `herdr api schema --json` reports schema version 1 and terminal protocol 22. These are observations, not compatibility requirements to hardcode. Runtime checks used an isolated `xherdr-ui-test` server and temporary XDG configuration and state directories. xherdr now follows server-provided agent views; the remaining integration steps below are proposed work. It does not yet provide a plugin manager or plugin action palette.

## Manifest and command model

The manifest requires `id`, `name`, `version`, and `min_herdr_version`. It can declare `description`, `platforms`, and arrays of `build`, `startup`, `actions`, `events`, `panes`, and `link_handlers`. Platforms are `macos`, `linux`, and `windows`. Missing platform declarations produce a warning; an item's declaration overrides the plugin's platform declaration. A minimum Herdr version newer than the running binary fails validation with `plugin_requires_newer_herdr`. See the [manifest loader](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/app/api/plugins/manifest.rs).

```toml
id = "example.tools"
name = "Example tools"
version = "0.1.0"
min_herdr_version = "0.9.3"
platforms = ["macos", "linux"]

[[build]]
command = ["cargo", "build", "--release", "--locked"]

[[startup]]
command = ["./target/release/example-tools", "startup"]

[[actions]]
id = "inspect"
title = "Inspect workspace"
contexts = ["workspace", "pane"]
command = ["./target/release/example-tools", "inspect"]

[[events]]
on = "workspace.created"
command = ["./target/release/example-tools", "workspace-created"]

[[panes]]
id = "board"
title = "Workspace board"
placement = "tab"
command = ["./target/release/example-tools", "board"]

[[link_handlers]]
id = "issue"
title = "Inspect issue"
pattern = '^https://example\.com/issues/[0-9]+$'
action = "inspect"
```

This is an illustrative manifest; it requires a package providing the referenced executable. Commands are argument arrays, without automatic shell expansion. A relative executable containing a path separator is resolved against the plugin root; a bare executable name is looked up through `PATH`. Actions and hooks run with the plugin root as their working directory. A pane can override its working directory through `plugin.pane.open`. A shell must be an explicit command if a plugin needs shell syntax. See [command execution](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/plugin_command.rs).

Plugin IDs accept ASCII letters, digits, `:`, `.`, `_`, and `-`, up to 120 characters. Local action, pane, and link handler IDs use the same set without dots and must be unique within their respective kind. An action's qualified ID is `<plugin-id>.<action-id>`, such as `example.tools.inspect`. Action contexts are `global`, `workspace`, `tab`, `pane`, and `selection`; they describe where an action is useful and do not restrict its API access. The manifest provides the action catalog; this API does not dynamically register native views or actions.

## Installation and registry

`herdr plugin link /absolute/path/to/plugin` registers a development directory, or a manifest path, without running its build commands. It enables the plugin by default; `--disabled` registers it without enabling execution. `herdr plugin install owner/repo[/subdir] --ref REF` clones a GitHub repository, validates the manifest, asks for installation confirmation, and runs the applicable build commands before registration. `--yes` bypasses the interactive confirmation. Installation records the requested ref and resolved commit. Build failure aborts installation. See [CLI plugins](https://herdr.dev/docs/cli-reference/#plugins) and the [installer](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/cli/plugin.rs).

The [marketplace](https://herdr.dev/docs/marketplace/) supplies discovery and package links; local linking remains available for development. There is no separate update command in 0.9.3: reinstalling a GitHub source replaces its managed checkout, while a collision with a locally linked plugin is rejected. `unlink` unregisters a plugin and retains its files. `uninstall` also removes a GitHub-managed checkout, but retains the plugin's configuration and state. Installation and execution run commands with the user's filesystem and process access; the manifest is not a sandbox or a permission grant system.

The registry is global to the user's Herdr configuration directory: on this macOS installation, it is `~/.config/herdr/plugins.json`. A named session does **not** give plugins a separate registry. Linking, listing, enabling, and disabling can work without a running server. Servers refresh the registry and reload manifests before relevant operations, so an existing server can see registry changes without a restart. Missing or invalid manifests remain visible through warnings, with execution unavailable. See [registry persistence](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/persist/plugin_registry.rs) and [registry refresh](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/app/api/plugins/mod.rs).

Default configuration and state paths are `~/.config/herdr/plugins/config/<encoded-plugin-id>` and `~/.local/state/herdr/plugins/<encoded-plugin-id>`. Managed GitHub checkouts live below `~/.config/herdr/plugins/github/`. Plugins should use the injected directories, or `herdr plugin config-dir PLUGIN_ID`, because path components may be escaped or hashed. `XDG_CONFIG_HOME` and `XDG_STATE_HOME` change the corresponding roots. `HERDR_CONFIG_PATH` changes the TOML configuration file, without isolating the plugin registry. See [plugin paths](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/plugin_paths.rs) and [configuration paths](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/config/io.rs).

## Invocation context and environment

The server injects `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_ENV=1`, `HERDR_PLUGIN_ID`, `HERDR_PLUGIN_ROOT`, `HERDR_PLUGIN_CONFIG_DIR`, `HERDR_PLUGIN_STATE_DIR`, and `HERDR_PLUGIN_CONTEXT_JSON`. Workspace, tab, and pane IDs also have convenience variables when available: `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, and `HERDR_PANE_ID`. Actions receive the local `HERDR_PLUGIN_ACTION_ID`; startup and event hooks receive `HERDR_PLUGIN_EVENT`; lifecycle hooks also receive `HERDR_PLUGIN_EVENT_JSON`. Pane commands receive `HERDR_PLUGIN_ENTRYPOINT_ID`. Link actions additionally receive `HERDR_PLUGIN_CLICKED_URL` and `HERDR_PLUGIN_LINK_HANDLER_ID`. See [command environment construction](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/app/api/plugins/runtime.rs) and [pane environment construction](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/app/api/plugins/panes.rs).

The JSON context can include workspace and tab IDs, labels, working directories, worktree information, focused pane ID and directory, agent and status, selected text, clicked URL, link handler ID, invocation source, and correlation ID. Fields are optional. A headless server's startup hook can run before any workspace exists, so plugins must handle an empty workspace context.

Without an explicit context, action invocation uses the server's current focus. The CLI command's working directory and its inherited `HERDR_PANE_ID` do not select the target. API context fields override the server defaults individually, with missing fields filled from current state. Overriding only `workspace_id` can therefore leave a pane or label from a different workspace. xherdr should construct a coherent context from its selected snapshot and include the selected text when invoking selection actions. See [context resolution](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/app/api/plugins/context.rs).

## Actions and control API

The JSON API exposes `plugin.link`, `plugin.list`, `plugin.unlink`, `plugin.enable`, `plugin.disable`, `plugin.action.list`, `plugin.action.invoke`, `plugin.log.list`, `plugin.pane.open`, `plugin.pane.focus`, and `plugin.pane.close`. The CLI has corresponding registration, action, log, and pane commands, plus GitHub installation and uninstallation. Use the installed binary's schema as the payload contract; the [plugin schema](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/api/schema/plugins.rs) defines the typed parameters and results.

```json
{"id":"plugins-1","method":"plugin.list","params":{}}
{"id":"actions-1","method":"plugin.action.list","params":{"plugin_id":"example.tools"}}
{"id":"invoke-1","method":"plugin.action.invoke","params":{"action_id":"example.tools.inspect","context":{"workspace_id":"w1","workspace_label":"Project","workspace_cwd":"/path/to/project","tab_id":"w1:t1","tab_label":"1","focused_pane_id":"w1:p1","focused_pane_cwd":"/path/to/project","invocation_source":"xherdr","correlation_id":"invoke-1"}}}
{"id":"logs-1","method":"plugin.log.list","params":{"plugin_id":"example.tools","limit":20}}
```

Each line is a separate request; the IDs and paths are placeholders to replace with snapshot values. Use qualified action IDs to avoid ambiguity between plugins. The invoke API accepts `action_id`, optional `plugin_id`, and optional `context`; it does not accept arbitrary action arguments. The executable arguments come from the manifest. `herdr plugin action invoke example.tools.inspect` is useful for diagnostics, but does not offer the API's explicit context override.

Discovery and execution are separate checks. The action list can contain actions belonging to disabled plugins, so xherdr should reconcile it with the plugin list before presenting enabled commands. Invocation can still fail if the plugin has been disabled, removed, or changed since discovery, or the action is unsupported on the server's platform. The UI should display the server's error and refresh its catalog. See [action handlers](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/app/api/plugins/mod.rs).

## Startup, events, and command logs

Startup commands run asynchronously after server bootstrap and restored state are ready, including the server handoff path. Linking or enabling a plugin, attaching another client, or reloading configuration does not itself run startup. These are executable invocations, without a daemon supervision or restart policy; failure is recorded without preventing server startup. See [headless bootstrap](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/server/headless/bootstrap.rs) and [hook execution](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/app/api/plugins/runtime.rs).

The plugin hook event set is narrower than `events.subscribe`. Version 0.9.3 supports `workspace.created`, `updated`, `closed`, `renamed`, `moved`, `reordered`, and `focused`; `worktree.created`, `opened`, and `removed`; `tab.created`, `closed`, `renamed`, `moved`, and `focused`; and `pane.created`, `closed`, `focused`, `moved`, `exited`, `agent_detected`, and `agent_status_changed`. Each suffix in this list uses its stated prefix. `pane.output_changed`, `pane.updated`, `layout.updated`, and `workspace.metadata_updated` are not hook selectors. Unknown selectors produce warnings rather than rejecting the plugin, and do not execute. See [supported hook events](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/api/schema/events.rs).

`HERDR_PLUGIN_EVENT` uses a dotted selector such as `workspace.created`, while `HERDR_PLUGIN_EVENT_JSON` contains the socket event envelope with an underscore event name such as `workspace_created`. Hooks run asynchronously, so a plugin should avoid depending on command completion order. A hook that creates or modifies the same resource can trigger more hooks; idempotence and recursion guards belong in the plugin.

Action invocation returns an initial `running` log before the command has completed. Even a missing executable can be accepted initially and fail later. `plugin.log.list` reports `running`, `succeeded`, or `failed`, along with the command, timestamps, exit code, captured output, and spawn errors. xherdr should track the returned log ID and poll for completion before reporting success. Version 0.9.3 keeps at most 200 command logs in server memory, caps each stdout/stderr capture at 64 KiB, and allows 32 action/hook commands in flight. These source limits are diagnostics, not a stable API promise, and the command logs do not survive server restart. See [command runtime](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/app/api/plugins/runtime.rs).

## Terminal panes and popups

Pane entrypoints launch terminal programs through `plugin.pane.open`. The manifest defaults to `overlay`; a request can override placement with `overlay`, `split`, `tab`, `zoomed`, or `popup`. Ordinary plugin panes have normal pane IDs and participate in the layout and pane lifecycle. `split` and `zoomed` accept a target pane and `right` or `down` direction; `zoomed` zooms the resulting split. `tab` can target a workspace. An overlay temporarily zooms over the active pane and restores the preceding focus and zoom state when closed. Overlay and popup placement use the active context and reject explicit workspace or pane targets. See [pane handling](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/app/api/plugins/panes.rs).

```json
{"id":"board-1","method":"plugin.pane.open","params":{"plugin_id":"example.tools","entrypoint":"board","placement":"tab","workspace_id":"w1","focus":true}}
```

Normal pane opening returns `plugin_pane_opened`, including the new pane's IDs. The process working directory defaults to the plugin root unless the caller specifies `cwd`. The injected `HERDR_PANE_ID` and `HERDR_TAB_ID` describe the new pane, while `HERDR_PLUGIN_CONTEXT_JSON` describes the launch context, including the previously focused pane. A plugin should use the appropriate identity for its operation. The API's `focus` default is false, so a native UI should send it explicitly.

A popup is a separate session-wide modal terminal, with no public pane ID and no ordinary pane lifecycle, layout, agent, or persistence behavior. Opening returns `ok`; `popup.close` closes it, rather than `plugin.pane.close`. Only one popup can be open. Popup commands do not receive their own `HERDR_PANE_ID`; context can still describe the underlying focused pane. Optional `width` and `height` are outer dimensions in cells or percentages such as `"80%"`. Input, including Escape, belongs to the popup program; process exit closes the popup. The installed CLI accepts `--placement popup`, although its 0.9.3 pane-open help omits it. See [popup implementation](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/app/api/plugins/panes.rs).

Disabling a plugin prevents future invocations and hooks; it does not terminate already running commands or panes. Unlinking drops plugin pane ownership records while the terminal panes continue running. Closing an owned pane with `plugin.pane.close` before unlinking is therefore a separate operation. See [disable and unlink handling](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/app/api/plugins/mod.rs).

## Keyboard shortcuts and link handlers

Herdr configuration can map a key directly to a qualified plugin action:

```toml
[[keys.command]]
key = "prefix+u"
type = "plugin_action"
command = "example.tools.inspect"
description = "Inspect workspace"
```

Link handlers associate a Rust regular expression with an action from the same manifest. A matching link activation adds the clicked URL and handler ID to the action context. Herdr's terminal client uses Ctrl-click for plugin link activation, including on macOS. The native client can use the server's `pane.link.activate` API to resolve and activate a link at a pane cell, rather than maintaining its own plugin regex matching rules. See [plugin bindings and link handlers](https://herdr.dev/docs/plugins/).

## xherdr integration boundary

xherdr already connects to the control API, follows pane lifecycle events, and renders normal pane surfaces. Those mechanisms should carry ordinary plugin-created panes; this is an inference from the current architecture, not a completed native UI check. Plugin discovery and invocation can use the existing JSON connection. Plugin commands still run on the Herdr server's host, so an SSH connection requires plugins and dependencies on that remote host. Local paths cannot be passed as remote plugin paths.

The current [shortcut loader](../xherdr/HerdrShortcuts.swift) reads supported built-in bindings and does not load `[[keys.command]]` plugin actions. The [command palette](../xherdr/CommandPalette.swift) has no plugin action catalog. The [surface decoder](../xherdr/HerdrSurface.swift) skips popup content and the renderer excludes popup graphics, so opening a popup is not yet a supported xherdr interaction. The [terminal view](../xherdr/TerminalPaneView.swift) opens Command-click web links through `NSWorkspace`; it does not route them through `pane.link.activate` and plugin handlers.

Plugins can change the TUI's agent presentation through `agent.view.set` and `agent.view.clear`, without registering custom UI widgets. The query provides a source, optional label, filter, and sort rules. xherdr's [native evaluator](../xherdr/HerdrAgentView.swift) consumes the `agent_view_projection` endpoint capability, pairs the query with the complete agent facts, and evaluates current-workspace and current-tab context from the native selection. The Agents header shows the label and source and offers a local bypass. The existing selected-Space filter remains an intersection with the server view. Unsupported queries fall back to the ordinary list with an **Unavailable** indicator. See [Agent views](herdr-connection.md#agent-views) for synchronization, completion tracking, and validation details, and the [Herdr query definition](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/app/agent_view.rs) for the checked contract.

## Validation

A local fixture linked without a server, appeared in another named session's offline listing, and did not execute its declared build command. With the isolated server running, startup succeeded without workspace context; a `workspace.created` hook received its event envelope; CLI actions used server focus despite a different caller pane variable; and an explicit API context selected a second workspace. An invocation with a missing executable first returned `running`, then recorded a failed log with the spawn error.

The same fixture opened and closed a normal tab pane, verified the distinction between the new pane's environment IDs and its launch context, opened a popup through the CLI, and closed it through `popup.close`. Disabling rejected an action with `plugin_disabled`; unlinking retained the fixture files and state. The server was stopped after the checks. The real plugin registry was not modified, and no third-party plugin was installed. GitHub installation, Windows execution, SSH execution, and native popup rendering were assessed from source and documentation, without runtime validation.

## Implementation order

1. Add plugin and action discovery to the command palette, reconcile enabled and platform state, send coherent selected context, and display invocation errors and completion logs.
2. Add a plugin manager with source, version, warnings, enable/disable, and local linking controls. Make the shared registry scope visible when changing it from a session-specific window.
3. Expose ordinary pane entrypoints with explicit target and focus parameters. Implement popup surface rendering, graphics, input routing, and dismissal before offering popup entrypoints.
4. Load `[[keys.command]]` plugin bindings and route link activation through Herdr. Verify both against the installed schema and an isolated server.

For development checks, isolate both the named session and the XDG configuration/state roots. Use `herdr plugin list --json`, `herdr plugin action list`, `herdr plugin log list`, and `herdr api schema --json` to inspect the actual catalog and contract before invoking anything.
