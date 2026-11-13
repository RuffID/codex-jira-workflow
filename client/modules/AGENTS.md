# Jira modules

- `JiraApi.psm1`: fixed Jira REST resources, environment authentication, pagination, ADF text and attachment streaming. Never expose a generic HTTP command or send authorization to a redirect destination.

- `JiraStorage.psm1`: read-only repository registration, account-scoped state, exclusive lock, atomic JSON, operation records and monthly retention. Artifact retention is separate: expire snapshots/downloads after 30 days without client use, checked at most once per 24 hours. Validate complete owned trees before deletion and never follow reparse points. Unknown/pending operations must survive all artifact cleanup.
- `JiraOperations.psm1`: reads, immutable mutation proposals, execution and reconciliation. Persist sending before POST; never automatically resend an uncertain mutation.

Project discovery uses only GET `myself` and paginated GET `project/search`, returning IDs, keys and names. It must not write configuration, cache or operation records; project discovery grants no permission to use the returned projects for task operations.

An approved mutation authorizes only the reviewed operation. Keep preparation and execution separate, preserve the request hash, and revalidate current Jira permissions/workflow at execution.

Attachment caching is per issue/attachment ID and verifies metadata, size and SHA-256 before reuse. New content downloads over 500,000,000 bytes require explicit approval for the selected ID; do not treat an unrelated file approval as blanket consent.
