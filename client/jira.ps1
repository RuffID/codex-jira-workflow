#requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('GetProjects', 'GetIssue', 'DownloadAttachments', 'GetTransitions', 'GetCatalog', 'GetCreateFields', 'PrepareWorklog', 'PrepareTransition', 'PrepareIssue', 'Execute', 'Reconcile', 'GetOperation', 'Cancel')][string]$Command,
    [string]$RepositoryPath,
    [string]$IssueKey,
    [string]$ProjectKey,
    [string]$IssueTypeId,
    [string]$PayloadPath,
    [string]$OperationId,
    [string]$RequestHash,
    [string]$ResultIssueKey,
    [string[]]$AttachmentIds = @(),
    [string[]]$ApprovedLargeAttachmentIds = @(),
    [switch]$WithAttachments,
    [switch]$Refresh,
    [switch]$Confirmed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$context = $null
$stateLock = $null

try {
    if ($Command -eq 'GetProjects') {
        foreach ($parameterName in $PSBoundParameters.Keys) {
            if ($parameterName -ne 'Command') { throw 'GetProjects accepts only Command; it does not use repository or mutation parameters.' }
        }
        Import-Module (Join-Path $PSScriptRoot 'modules/JiraApi.psm1') -Force -DisableNameChecking
        $context = New-JiraContext
        $identity = Invoke-JiraJson $context 'GET' 'myself'
        if (-not $identity['accountId']) { throw 'Jira did not return the authenticated account ID.' }
        $projects = @(Get-JiraProjects $context)
        ConvertTo-Json -InputObject @{
            ok = $true; command = $Command; cleanedOperations = 0
            cleanedArtifacts = @{ ran = $false; filesRemoved = 0; bytesRemoved = 0L; directoriesRemoved = 0 }
            data = @{ projects = $projects; count = $projects.Count }
        } -Depth 100
        return
    }
    if (-not $RepositoryPath) { throw 'RepositoryPath is required for this command.' }
    Import-Module (Join-Path $PSScriptRoot 'modules/JiraStorage.psm1') -Force -DisableNameChecking
    $root = Split-Path $PSScriptRoot -Parent
    $binding = Get-JiraBinding $root $RepositoryPath
    if ($IssueKey) { Assert-JiraAllowedIssue $binding $IssueKey }
    if ($ProjectKey) { Assert-JiraAllowedProject $binding $ProjectKey }
    if ($ResultIssueKey) { Assert-JiraAllowedIssue $binding $ResultIssueKey }
    if ($Command -in @('GetIssue', 'DownloadAttachments', 'GetTransitions') -and -not $IssueKey) { throw 'IssueKey is required.' }
    if ($Command -eq 'GetCreateFields' -and (-not $ProjectKey -or -not $IssueTypeId)) { throw 'ProjectKey and IssueTypeId are required.' }
    if ($Command -in @('PrepareWorklog', 'PrepareTransition', 'PrepareIssue') -and -not $PayloadPath) { throw 'PayloadPath is required.' }
    if ($Command -in @('Execute', 'Reconcile', 'GetOperation', 'Cancel') -and -not $OperationId) { throw 'OperationId is required.' }
    if ($Command -eq 'Execute' -and (-not $Confirmed -or -not $RequestHash)) { throw 'Execute requires Confirmed and the reviewed RequestHash.' }
    if ($ApprovedLargeAttachmentIds.Count -gt 0 -and $Command -ne 'DownloadAttachments' -and -not ($Command -eq 'GetIssue' -and $WithAttachments)) { throw 'Large-file approval is only valid for attachment downloads.' }
    Import-Module (Join-Path $PSScriptRoot 'modules/JiraApi.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'modules/JiraOperations.psm1') -Force -DisableNameChecking
    $inputData = $null
    if ($PayloadPath) {
        $inputData = Read-JiraJson ([IO.Path]::GetFullPath($PayloadPath))
        if ($inputData -isnot [Collections.IDictionary]) { throw 'Payload must be a JSON object.' }
        if ($inputData.Contains('issueKey')) { Assert-JiraAllowedIssue $binding $inputData.issueKey }
        if ($Command -eq 'PrepareIssue') { Assert-JiraAllowedProject $binding ([string]$inputData['fields']['project']['key']) }
    }
    $context = New-JiraContext
    $identity = Invoke-JiraJson $context 'GET' 'myself'
    if (-not $identity['accountId']) { throw 'Jira did not return the authenticated account ID.' }
    $context.accountId = [string]$identity.accountId
    $statePath = Initialize-JiraState $root $context.siteIdentity $context.accountId
    $stateLock = Enter-JiraStateLock $statePath
    $cleanupCount = Invoke-JiraMonthlyCleanup $statePath
    $artifactCleanup = Invoke-JiraDailyArtifactCleanup $statePath
    $result = switch ($Command) {
        'GetIssue' { Get-JiraIssueBundle $context $binding $statePath $IssueKey -WithAttachments:$WithAttachments -AttachmentIds $AttachmentIds -ApprovedLargeAttachmentIds $ApprovedLargeAttachmentIds }
        'DownloadAttachments' {
            $issue = Get-JiraIssue $context $IssueKey
            if ($issue.key -cne $IssueKey) { throw 'Jira issue key changed; review it before proceeding.' }
            Save-JiraIssueAttachments $context $binding $statePath $issue $AttachmentIds $ApprovedLargeAttachmentIds
        }
        'GetTransitions' {
            $issue = Get-JiraIssue $context $IssueKey
            if ($issue.key -cne $IssueKey) { throw 'Jira issue key changed; review it before proceeding.' }
            Assert-JiraAllowedProject $binding $issue.fields.project.key
            @{ issueKey = $IssueKey; currentStatus = $issue.fields.status; transitions = Get-JiraTransitions $context $IssueKey }
        }
        'GetCatalog' { Get-JiraCatalog $context $binding $statePath -Refresh:$Refresh }
        'GetCreateFields' { @{ projectKey = $ProjectKey; issueTypeId = $IssueTypeId; fields = Get-JiraCreateFields $context $ProjectKey $IssueTypeId } }
        'PrepareWorklog' { New-JiraProposal $context $binding $statePath 'worklog' $inputData }
        'PrepareTransition' { New-JiraProposal $context $binding $statePath 'transition' $inputData }
        'PrepareIssue' { New-JiraProposal $context $binding $statePath 'create' $inputData }
        'Execute' { Invoke-JiraApprovedOperation $context $binding $statePath $OperationId $RequestHash -Confirmed:$Confirmed }
        'Reconcile' { Sync-JiraOperation $context $binding $statePath $OperationId $ResultIssueKey }
        'GetOperation' {
            $operation = Read-JiraOperation $statePath $OperationId
            Assert-JiraOperationOwner $context $binding $operation
            $operation
        }
        'Cancel' {
            $operation = Read-JiraOperation $statePath $OperationId
            Assert-JiraOperationOwner $context $binding $operation
            if ($operation.status -ne 'prepared') { throw 'Only a prepared, unsent operation can be cancelled.' }
            $operation.status = 'cancelled'; $operation.completedAt = [datetimeoffset]::UtcNow.ToString('o')
            Save-JiraOperation $statePath $operation
            $operation
        }
    }
    ConvertTo-Json -InputObject @{ ok = $true; command = $Command; cleanedOperations = $cleanupCount; cleanedArtifacts = $artifactCleanup; data = $result } -Depth 100
}
catch {
    [Console]::Error.WriteLine((ConvertTo-Json -InputObject @{ ok = $false; message = $_.Exception.Message } -Compress))
    exit 1
}
finally {
    if ($null -ne $stateLock) { $stateLock.Dispose() }
    if ($null -ne $context) { $context.client.Dispose() }
}
