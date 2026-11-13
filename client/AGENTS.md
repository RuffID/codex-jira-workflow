# Jira client

PowerShell 7.5+ entry point for the approved Jira workflow. `jira.ps1` validates local registration before credentials or network access, loads the four modules, and prints JSON results. Configuration changes are outside the client commands and require explicit user authorization. Never add example repository bindings.

`GetProjects` is an explicit read-only discovery command: it verifies the authenticated account and lists visible project IDs, keys and names without reading configuration, importing storage/operations, creating state, running cleanup or registering repositories. All other commands still require `RepositoryPath` and registration before credentials or HTTP.

The repository root (parent of `client/`) owns `config.json` and runtime `data/`. Resolve it relative to the entry point; do not fall back to AppData or another checkout.

`LogWorklog` requires a caller-supplied stable operation UUID, payload and explicit confirmation before authentication. It performs immutable preparation and approved execution in one session under the account lock. Existing prepared proposals still use `Execute` with their reviewed hash; uncertain operations require reconciliation.

Do not execute this client, its modules as scripts, or tests without the applicable user permission. Syntax parsing is not execution. Tests must use a fake transport and isolated storage, never Jira, actual credentials or the production configuration.

Issue creation can include reviewed links and attachments. `PrepareLink` and `PrepareAttachments` also work on existing issues. A workflow records each mutation separately; `partial` retains completed steps, and `unknown` requires reconciliation before continuation. File rendering is explicitly attachment links, never an unverified inline-media fallback. Existing description updates append ADF nodes and check for changes since preparation.
