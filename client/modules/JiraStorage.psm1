#requires -Version 7.5
Set-StrictMode -Version Latest

function Get-JiraHash {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Read-JiraJson {
    param([Parameter(Mandatory)][string]$Path)
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path, $encoding)) -AsHashtable -Depth 100 -DateKind String -NoEnumerate)
}

function Assert-JiraPlainPath {
    param([Parameter(Mandatory)][string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) {
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Reparse points are not allowed in client storage or repository paths.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Get-JiraNormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'An absolute repository path is required.' }
    return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
}

function Get-JiraBinding {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RepositoryPath)
    $path = Get-JiraNormalizedPath $RepositoryPath
    if (-not [IO.Directory]::Exists($path)) { throw 'Repository directory does not exist.' }
    Assert-JiraPlainPath $path
    $configPath = Join-Path $Root 'config.json'
    if (-not [IO.File]::Exists($configPath)) { throw 'Repository is not registered.' }
    Assert-JiraPlainPath $configPath
    $config = Read-JiraJson $configPath
    if ($config.schemaVersion -ne 1 -or -not $config.Contains('repositories')) { throw 'Invalid Jira configuration schema.' }
    $matches = @(
        foreach ($entry in $config.repositories) {
            $registered = Get-JiraNormalizedPath $entry.path
            $prefix = $registered.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if ($path.Equals($registered, [StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $keys = @($entry.jiraProjectKeys)
                if ($keys.Count -eq 0) { throw 'Registered repository has no allowed Jira projects.' }
                foreach ($key in $keys) {
                    if ($key -cnotmatch '^[A-Z][A-Z0-9_]*$') { throw 'Invalid project key in Jira configuration.' }
                }
                @{ path = $registered; jiraProjectKeys = $keys }
            }
        }
    )
    if ($matches.Count -eq 0) { throw 'Repository is not registered.' }
    $ordered = @($matches | Sort-Object { $_.path.Length } -Descending)
    if ($ordered.Count -gt 1 -and $ordered[0].path.Length -eq $ordered[1].path.Length) { throw 'Duplicate repository bindings are ambiguous.' }
    return $ordered[0]
}

function Assert-JiraAllowedProject {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Binding, [Parameter(Mandatory)][string]$ProjectKey)
    if ($ProjectKey -cnotmatch '^[A-Z][A-Z0-9_]*$' -or $ProjectKey -cnotin $Binding.jiraProjectKeys) {
        throw 'Project is not allowed for this repository.'
    }
}

function Assert-JiraAllowedIssue {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Binding, [Parameter(Mandatory)][string]$IssueKey)
    if ($IssueKey -cnotmatch '^([A-Z][A-Z0-9_]*)-[1-9][0-9]*$') { throw 'An uppercase Jira issue key is required.' }
    Assert-JiraAllowedProject $Binding $Matches[1]
}

function Initialize-JiraState {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$SiteIdentity, [Parameter(Mandatory)][string]$AccountId)
    $state = Join-Path (Join-Path (Join-Path $Root 'data') (Get-JiraHash $SiteIdentity)) (Get-JiraHash $AccountId)
    Assert-JiraPlainPath $state
    [void][IO.Directory]::CreateDirectory($state)
    foreach ($name in @('operations', 'snapshots', 'downloads')) { [void][IO.Directory]::CreateDirectory((Join-Path $state $name)) }
    return $state
}

function Enter-JiraStateLock {
    param([Parameter(Mandatory)][string]$StatePath)
    $path = Join-Path $StatePath 'state.lock'
    Assert-JiraPlainPath $path
    try { return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Another client operation is using this account state, or the state directory is inaccessible.' }
}

function Write-JiraJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    Assert-JiraPlainPath $Path
    $directory = [IO.Path]::GetDirectoryName($Path)
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ([IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $stream = $null
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 100))
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose(); $stream = $null
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Get-JiraOperationPath {
    param([Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][string]$OperationId)
    $id = [guid]::Empty
    if (-not [guid]::TryParseExact($OperationId, 'D', [ref]$id)) { throw 'Operation ID must be a full UUID.' }
    return (Join-Path (Join-Path $StatePath 'operations') ($id.ToString('D') + '.json'))
}

function Save-JiraOperation {
    param([Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][System.Collections.IDictionary]$Operation)
    Write-JiraJson (Get-JiraOperationPath $StatePath $Operation.id) $Operation
}

function Read-JiraOperation {
    param([Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][string]$OperationId)
    $path = Get-JiraOperationPath $StatePath $OperationId
    Assert-JiraPlainPath $path
    $operation = Read-JiraJson $path
    if ($operation.schemaVersion -ne 1 -or $operation.id -cne $OperationId -or (Get-JiraHash $operation.requestJson) -cne $operation.requestHash) {
        throw 'Operation record is invalid or its request has changed.'
    }
    return $operation
}

function Invoke-JiraMonthlyCleanup {
    param([Parameter(Mandatory)][string]$StatePath, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $markerPath = Join-Path $StatePath 'maintenance.json'
    $month = $Now.ToString('yyyy-MM')
    if ([IO.File]::Exists($markerPath)) {
        $marker = Read-JiraJson $markerPath
        if ($marker.lastCleanupMonth -eq $month) { return 0 }
    }
    $operationsPath = [IO.Path]::GetFullPath((Join-Path $StatePath 'operations'))
    Assert-JiraPlainPath $operationsPath
    $count = 0
    foreach ($file in [IO.Directory]::EnumerateFiles($operationsPath, '*.json', [IO.SearchOption]::TopDirectoryOnly)) {
        $name = [IO.Path]::GetFileNameWithoutExtension($file)
        $expected = Get-JiraOperationPath $StatePath $name
        if (-not [IO.Path]::GetFullPath($file).Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected cleanup target.' }
        Assert-JiraPlainPath $expected
        $operation = Read-JiraOperation $StatePath $name
        if ($operation.status -in @('completed', 'failed', 'cancelled') -and $operation.Contains('completedAt') -and $operation.completedAt) {
            if ([datetimeoffset]::Parse($operation.completedAt, [cultureinfo]::InvariantCulture) -lt $Now.AddDays(-90)) {
                [IO.File]::Delete($expected)
                $count++
            }
        }
    }
    Write-JiraJson $markerPath @{ lastCleanupMonth = $month; completedAt = $Now.ToString('o') }
    return $count
}

function Get-JiraOwnedTree {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Directory)
    $rootPath = Get-JiraNormalizedPath $Root
    $target = Get-JiraNormalizedPath $Directory
    $prefix = $rootPath.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Artifact directory is outside its owned storage root.' }
    Assert-JiraPlainPath $target
    $files = [Collections.Generic.List[string]]::new()
    $directories = [Collections.Generic.List[string]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($target)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        Assert-JiraPlainPath $current
        $directories.Add($current)
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current, '*', [IO.SearchOption]::TopDirectoryOnly)) {
            $resolved = [IO.Path]::GetFullPath($entry)
            if (-not $resolved.StartsWith($target + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected artifact deletion target.' }
            Assert-JiraPlainPath $resolved
            if ([IO.Directory]::Exists($resolved)) { $pending.Push($resolved) }
            else { $files.Add($resolved) }
        }
    }
    return @{ files = $files.ToArray(); directories = $directories.ToArray() }
}

function Remove-JiraOwnedDirectory {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Directory)
    # Validate the entire tree before deleting anything. Never follow junctions.
    $tree = Get-JiraOwnedTree $Root $Directory
    $bytes = 0L
    foreach ($file in $tree.files) { $bytes += ([IO.FileInfo]::new($file)).Length }
    foreach ($file in $tree.files) { [IO.File]::Delete($file) }
    foreach ($child in @($tree.directories | Sort-Object Length -Descending)) { [IO.Directory]::Delete($child, $false) }
    return @{ filesRemoved = $tree.files.Count; bytesRemoved = $bytes; directoriesRemoved = $tree.directories.Count }
}

function Update-JiraArtifactUsage {
    param([Parameter(Mandatory)][string]$Directory, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    Write-JiraJson (Join-Path $Directory 'usage.json') @{ schemaVersion = 1; lastUsedAt = $Now.ToString('o') }
}

function Get-JiraArtifactLastUse {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Directory)
    $tree = Get-JiraOwnedTree $Root $Directory
    $usagePath = Join-Path $Directory 'usage.json'
    if ([IO.File]::Exists($usagePath)) {
        $usage = Read-JiraJson $usagePath
        if ($usage.schemaVersion -ne 1 -or -not $usage['lastUsedAt']) { throw 'Invalid artifact usage metadata.' }
        return [datetimeoffset]::Parse($usage.lastUsedAt, [cultureinfo]::InvariantCulture)
    }
    # Directories made by the previous client have no usage record. Their last
    # write time provides a conservative migration date; never use last access.
    $latest = [datetimeoffset]([IO.Directory]::GetLastWriteTimeUtc($Directory))
    foreach ($file in $tree.files) {
        $written = [datetimeoffset]([IO.File]::GetLastWriteTimeUtc($file))
        if ($written -gt $latest) { $latest = $written }
    }
    return $latest
}

function Invoke-JiraDailyArtifactCleanup {
    param([Parameter(Mandatory)][string]$StatePath, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $markerPath = Join-Path $StatePath 'artifact-maintenance.json'
    Assert-JiraPlainPath $markerPath
    $result = @{ ran = $false; filesRemoved = 0; bytesRemoved = 0L; directoriesRemoved = 0 }
    if ([IO.File]::Exists($markerPath)) {
        $marker = Read-JiraJson $markerPath
        if ([datetimeoffset]::Parse($marker.lastCleanupAt, [cultureinfo]::InvariantCulture) -gt $Now.AddHours(-24)) { return $result }
    }
    $cutoff = $Now.AddDays(-30)
    foreach ($kind in @('downloads', 'snapshots')) {
        $ownedRoot = Join-Path $StatePath $kind
        Assert-JiraPlainPath $ownedRoot
        foreach ($issueDirectory in @([IO.Directory]::EnumerateDirectories($ownedRoot))) {
            if ([IO.Path]::GetFileName($issueDirectory) -cnotmatch '^[A-Z][A-Z0-9_]*-[1-9][0-9]*$') { throw 'Unexpected issue artifact directory.' }
            Assert-JiraPlainPath $issueDirectory
            $removedChild = $false
            foreach ($bundleDirectory in @([IO.Directory]::EnumerateDirectories($issueDirectory))) {
                $name = [IO.Path]::GetFileName($bundleDirectory)
                $parsedId = [guid]::Empty
                $isBundle = [guid]::TryParseExact($name, 'D', [ref]$parsedId)
                if (-not $isBundle -and -not ($kind -eq 'downloads' -and $name -match '^[0-9]+$')) { throw 'Unexpected artifact cache directory.' }
                if ((Get-JiraArtifactLastUse $ownedRoot $bundleDirectory) -lt $cutoff) {
                    $removed = Remove-JiraOwnedDirectory $ownedRoot $bundleDirectory
                    foreach ($counter in @('filesRemoved', 'bytesRemoved', 'directoriesRemoved')) { $result[$counter] += $removed[$counter] }
                    $removedChild = $true
                }
            }
            $remaining = @([IO.Directory]::EnumerateDirectories($issueDirectory))
            if ($remaining.Count -eq 0 -and ($removedChild -or (Get-JiraArtifactLastUse $ownedRoot $issueDirectory) -lt $cutoff)) {
                $removed = Remove-JiraOwnedDirectory $ownedRoot $issueDirectory
                foreach ($counter in @('filesRemoved', 'bytesRemoved', 'directoriesRemoved')) { $result[$counter] += $removed[$counter] }
            }
            elseif ($kind -eq 'downloads' -and $removedChild) {
                # The aggregate manifest is a view of the cache, never a second
                # owner of cached files. Rebuild it after expiring cache entries.
                $files = @(
                    foreach ($directory in $remaining) {
                        $recordPath = Join-Path $directory 'attachment.json'
                        if ([IO.File]::Exists($recordPath)) { Read-JiraJson $recordPath }
                    }
                )
                Write-JiraJson (Join-Path $issueDirectory 'manifest.json') @{ issueKey = [IO.Path]::GetFileName($issueDirectory); files = $files; skipped = @() }
            }
        }
    }
    Write-JiraJson $markerPath @{ schemaVersion = 1; lastCleanupAt = $Now.ToString('o') }
    $result.ran = $true
    return $result
}

Export-ModuleMember -Function Get-JiraHash, Read-JiraJson, Assert-JiraPlainPath, Get-JiraNormalizedPath, Get-JiraBinding, Assert-JiraAllowedProject, Assert-JiraAllowedIssue, Initialize-JiraState, Enter-JiraStateLock, Write-JiraJson, Get-JiraOperationPath, Save-JiraOperation, Read-JiraOperation, Invoke-JiraMonthlyCleanup, Get-JiraOwnedTree, Remove-JiraOwnedDirectory, Update-JiraArtifactUsage, Invoke-JiraDailyArtifactCleanup
