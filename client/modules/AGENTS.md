# Jira modules

- `JiraApi.psm1`: fixed Jira REST resources, environment authentication, pagination, ADF text and attachment streaming. Never expose a generic HTTP command or send authorization to a redirect destination.

- `JiraStorage.psm1`: read-only repository registration, account-scoped state, exclusive lock, atomic JSON, operation records and monthly retention. Artifact retention is separate: expire snapshots/downloads after 30 days without client use, checked at most once per 24 hours. Validate complete owned trees before deletion and never follow reparse points. Unknown/pending operations must survive all artifact cleanup.
- `JiraOperations.psm1`: reads, immutable mutation proposals, execution and reconciliation. Persist sending before POST; never automatically resend an uncertain mutation.
- `JiraIssueChanges.psm1`: reviewed issue links, attachment workflows, text-only description appends and standalone comments, multipart uploads through the API module, ADF append and per-step reconciliation. Keep file SHA-256, both issue scopes, link direction and description baselines in the reviewed request. Text-only appends and comments accept only issueKey/text and reuse their respective step without uploads. Standalone comments preserve the issue description and use the operation marker, exact body and author for reconciliation. Never derive Media IDs from private redirect structures or flatten existing ADF. Only description PUT is allowed; file uploads and comments are separate journalled steps.

Project discovery uses only GET `myself` and paginated GET `project/search`, returning IDs, keys and names. It must not write configuration, cache or operation records; project discovery grants no permission to use the returned projects for task operations.

An approved mutation authorizes only the reviewed operation. Preserve immutable preparation, the request hash, and current Jira permissions/workflow validation at execution. `LogWorklog` combines these stages within one command only for an already confirmed worklog; its caller supplies a stable UUID before sending, and retries must reuse that UUID and payload. Existing operations cannot be overwritten or uncertain mutations resent.

Issue validation requests only the fields needed by the caller. Full issue inspection keeps all fields and paginated comments.

Description and comment-body comparisons normalize only an omitted versus empty-array content field on paragraph nodes, matching Jira's returned ADF. Do not flatten rich content or apply this normalization to immutable request hashes.

Attachment caching is per issue/attachment ID and verifies metadata, size and SHA-256 before reuse. New content downloads over 500,000,000 bytes require explicit approval for the selected ID; do not treat an unrelated file approval as blanket consent.
