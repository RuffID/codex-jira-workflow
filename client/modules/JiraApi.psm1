#requires -Version 7.5
Set-StrictMode -Version Latest

function New-JiraContext {
    $siteText = [Environment]::GetEnvironmentVariable('JIRA_SITE_URL')
    $email = [Environment]::GetEnvironmentVariable('JIRA_EMAIL')
    $token = [Environment]::GetEnvironmentVariable('JIRA_API_TOKEN')
    $cloudId = [Environment]::GetEnvironmentVariable('JIRA_CLOUD_ID')
    if (-not $siteText -or -not $email -or -not $token) { throw 'Set JIRA_SITE_URL, JIRA_EMAIL and JIRA_API_TOKEN locally before connecting.' }
    $site = $null
    if (-not [uri]::TryCreate($siteText, [UriKind]::Absolute, [ref]$site) -or $site.Scheme -ne 'https' -or $site.Host -notmatch '^[a-z0-9-]+\.atlassian\.net$' -or $site.Port -ne 443 -or $site.UserInfo -or $site.Query -or $site.Fragment -or $site.AbsolutePath -ne '/') {
        throw 'JIRA_SITE_URL must be an HTTPS Atlassian Cloud site URL without a path, query or credentials.'
    }
    if ($email -match '[\r\n:]' -or $token -match '[\r\n]') { throw 'Invalid credential format.' }
    $siteUrl = $site.GetLeftPart([UriPartial]::Authority)
    $apiBase = "$siteUrl/rest/api/3/"
    if ($cloudId) {
        $parsedCloudId = [guid]::Empty
        if (-not [guid]::TryParseExact($cloudId, 'D', [ref]$parsedCloudId)) { throw 'JIRA_CLOUD_ID must be a UUID.' }
        $apiBase = 'https://api.atlassian.com/ex/jira/' + $parsedCloudId.ToString('D') + '/rest/api/3/'
    }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [timespan]::FromSeconds(60)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($email + ':' + $token))
    $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Basic', $encoded)
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'Codex-Jira-Local/1.0')
    return @{ client = $client; apiBase = $apiBase; siteUrl = $siteUrl; siteIdentity = "$siteUrl|$cloudId"; accountId = $null }
}

function Assert-JiraResource {
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Resource)
    $parts = $Resource.Split('?', 2)
    $path = $parts[0]
    $allowed = if ($Method -eq 'GET') {
        $path -cmatch '^(myself|project/search|issueLinkType|attachment/meta|issue/[A-Z][A-Z0-9_]*-[1-9][0-9]*(/(comment|worklog|transitions|properties/codex\.operation))?|project/[A-Z][A-Z0-9_]*(/statuses)?|issue/createmeta/[A-Z][A-Z0-9_]*/issuetypes(/[0-9]+)?|attachment/content/[0-9]+)$'
    } elseif ($Method -eq 'POST') {
        $path -cmatch '^(issue|issueLink|issue/[A-Z][A-Z0-9_]*-[1-9][0-9]*/(worklog|transitions|comment|attachments))$'
    } elseif ($Method -eq 'PUT') {
        $path -cmatch '^issue/[A-Z][A-Z0-9_]*-[1-9][0-9]*$'
    } else { $false }
    if (-not $allowed -or $Resource.Contains('#') -or $Resource.Contains('\') -or $Resource -match '[\r\n]') { throw 'HTTP resource is outside the client allowlist.' }
}

function New-JiraHttpError {
    param([int]$Status, [string]$Message, [bool]$Rejected)
    $error = [InvalidOperationException]::new($Message)
    $error.Data['JiraStatus'] = $Status
    $error.Data['DefinitelyRejected'] = $Rejected
    return $error
}

function Send-JiraHttp {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Resource, $Body, [switch]$Stream)
    Assert-JiraResource $Method $Resource
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), ($Context.apiBase + $Resource))
    if (-not $Stream) { [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/json') }
    if ($Body -is [Net.Http.MultipartFormDataContent]) {
        if ($Method -cne 'POST' -or $Resource -cnotmatch '^issue/[A-Z][A-Z0-9_]*-[1-9][0-9]*/attachments$') { $request.Dispose(); throw 'Multipart content is only supported for issue attachments.' }
        $request.Content = $Body
        [void]$request.Headers.TryAddWithoutValidation('X-Atlassian-Token', 'no-check')
    } elseif ($null -ne $Body) {
        if ($Method -ceq 'PUT' -and ($Body -isnot [Collections.IDictionary] -or $Body.Count -ne 1 -or -not $Body.Contains('fields') -or $Body.fields -isnot [Collections.IDictionary] -or $Body.fields.Count -ne 1 -or -not $Body.fields.Contains('description'))) {
            $request.Dispose(); throw 'Issue editing is limited to the reviewed description.'
        }
        $request.Content = [Net.Http.StringContent]::new((ConvertTo-Json -InputObject $Body -Depth 100 -Compress), [Text.Encoding]::UTF8, 'application/json')
    }
    try {
        try { $response = $Context.client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult() }
        catch { throw (New-JiraHttpError 0 'Jira connection failed or timed out. A sent mutation may have an unknown result.' $false) }
        $status = [int]$response.StatusCode
        if ($status -lt 200 -or $status -ge 300) {
            $response.Dispose()
            $rejected = $status -in @(400, 401, 403, 404, 405, 409, 413, 415, 422, 429)
            throw (New-JiraHttpError $status "Jira returned HTTP $status. No automatic retry was made." $rejected)
        }
        return $response
    }
    finally { $request.Dispose() }
}

function Invoke-JiraJson {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Resource, $Body = $null)
    $response = Send-JiraHttp $Context $Method $Resource $Body
    try {
        if ([int]$response.StatusCode -eq 204 -or $response.Content.Headers.ContentLength -eq 0) { return $null }
        try {
            $cts = [Threading.CancellationTokenSource]::new([timespan]::FromSeconds(60))
            try { $text = $response.Content.ReadAsStringAsync($cts.Token).GetAwaiter().GetResult() }
            finally { $cts.Dispose() }
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            $parsed = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 100 -DateKind String -NoEnumerate -ErrorAction Stop
            return ,$parsed
        }
        catch { throw (New-JiraHttpError ([int]$response.StatusCode) 'Jira response could not be read as JSON. Mutation outcome may be unknown.' $false) }
    }
    finally { $response.Dispose() }
}

function Get-JiraPagedItems {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$Resource, [Parameter(Mandatory)][string]$Collection)
    $all = [Collections.Generic.List[object]]::new()
    $start = 0
    do {
        $separator = if ($Resource.Contains('?')) { '&' } else { '?' }
        $page = Invoke-JiraJson $Context 'GET' ($Resource + $separator + "startAt=$start&maxResults=100")
        if (-not $page.Contains($Collection) -or -not $page.Contains('total') -or -not $page.Contains('startAt')) { throw 'Unexpected paginated Jira response.' }
        $items = @($page[$Collection])
        if ([int]$page.startAt -ne $start -or ($items.Count -eq 0 -and $start -lt [int]$page.total)) { throw 'Jira pagination did not advance; results may be incomplete.' }
        foreach ($item in $items) { $all.Add($item) }
        $start += $items.Count
    } while ($start -lt [int]$page.total)
    return ,$all.ToArray()
}

function Get-JiraProjects {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Context)
    $projects = Get-JiraPagedItems $Context 'project/search?orderBy=key' 'values'
    foreach ($project in $projects) {
        if (-not $project['id'] -or -not $project['key'] -or -not $project['name']) { throw 'Jira returned an incomplete project.' }
        @{ id = [string]$project.id; key = [string]$project.key; name = [string]$project.name }
    }
}

function Get-JiraIssue {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$IssueKey, [ValidateNotNullOrEmpty()][string[]]$Fields = @('*all'))
    $selection = [uri]::EscapeDataString(($Fields -join ','))
    return (Invoke-JiraJson $Context 'GET' "issue/${IssueKey}?fields=$selection")
}

function Get-JiraComments {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$IssueKey)
    return ,(Get-JiraPagedItems $Context "issue/$IssueKey/comment?orderBy=created" 'comments')
}

function Get-JiraWorklogs {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$IssueKey)
    return ,(Get-JiraPagedItems $Context "issue/$IssueKey/worklog" 'worklogs')
}

function Get-JiraTransitions {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$IssueKey)
    $result = Invoke-JiraJson $Context 'GET' "issue/$IssueKey/transitions?expand=transitions.fields"
    return ,@($result.transitions)
}

function Get-JiraCreateTypes {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$ProjectKey)
    return ,(Get-JiraPagedItems $Context "issue/createmeta/$ProjectKey/issuetypes" 'issueTypes')
}

function Get-JiraCreateFields {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$ProjectKey, [Parameter(Mandatory)][string]$IssueTypeId)
    if ($IssueTypeId -notmatch '^[0-9]+$') { throw 'Invalid issue type ID.' }
    return ,(Get-JiraPagedItems $Context "issue/createmeta/$ProjectKey/issuetypes/$IssueTypeId" 'fields')
}

function ConvertTo-JiraDocument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $paragraphs = @(
        foreach ($line in ($Text -split '\r?\n')) {
            if ($line.Length -eq 0) { @{ type = 'paragraph'; content = @() } }
            else { @{ type = 'paragraph'; content = @(@{ type = 'text'; text = $line }) } }
        }
    )
    return @{ type = 'doc'; version = 1; content = $paragraphs }
}

function ConvertFrom-JiraDocument {
    param([AllowNull()]$Document)
    if ($null -eq $Document) { return '' }
    if ($Document -is [string]) { return $Document }
    $builder = [Text.StringBuilder]::new()
    function Add-JiraDocumentNode {
        param($Node, [Text.StringBuilder]$Target)
        if ($Node -isnot [Collections.IDictionary]) { return }
        switch ($Node['type']) {
            'text' {
                [void]$Target.Append([string]$Node['text'])
                foreach ($mark in @($Node['marks'])) {
                    if ($null -ne $mark -and $mark['type'] -eq 'link') { [void]$Target.Append(' (' + [string]$mark['attrs']['href'] + ')') }
                }
            }
            'hardBreak' { [void]$Target.Append("`n") }
            'mention' { [void]$Target.Append([string]$Node['attrs']['text']) }
            'inlineCard' { [void]$Target.Append([string]$Node['attrs']['url']) }
        }
        foreach ($child in @($Node['content'])) { Add-JiraDocumentNode $child $Target }
        if ($Node['type'] -in @('paragraph', 'heading', 'codeBlock', 'listItem', 'tableRow', 'blockquote')) { [void]$Target.Append("`n") }
    }
    Add-JiraDocumentNode $Document $builder
    return $builder.ToString().TrimEnd("`r", "`n")
}

function Save-JiraAttachmentContent {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$AttachmentId, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][long]$ExpectedSize)
    if ($AttachmentId -notmatch '^[0-9]+$' -or $ExpectedSize -lt 0) { throw 'Invalid attachment metadata.' }
    $response = Send-JiraHttp $Context 'GET' "attachment/content/${AttachmentId}?redirect=false" $null -Stream
    $output = $null
    $inputStream = $null
    $cts = [Threading.CancellationTokenSource]::new([timespan]::FromMinutes(5))
    $partial = $Path + '.' + [guid]::NewGuid().ToString('N') + '.part'
    try {
        if ([int]$response.StatusCode -ne 200) { throw 'Attachment response is not a complete file.' }
        $inputStream = $response.Content.ReadAsStreamAsync($cts.Token).GetAwaiter().GetResult()
        $output = [IO.File]::Open($partial, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = [byte[]]::new(65536)
        $written = 0L
        while (($read = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult()) -gt 0) {
            $written += $read
            if ($written -gt $ExpectedSize) { throw 'Attachment exceeds the size declared by Jira.' }
            $output.Write($buffer, 0, $read)
        }
        if ($written -ne $ExpectedSize) { throw 'Attachment is incomplete or changed during download.' }
        $output.Flush($true)
        $output.Dispose(); $output = $null
        [IO.File]::Move($partial, $Path, $false)
    }
    finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        $response.Dispose(); $cts.Dispose()
        if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) }
    }
}

function Send-JiraAttachment {
    param($Context, [string]$IssueKey, [Collections.IDictionary]$File)
    # Hold a read-only handle from hash verification through transmission.
    $stream = [IO.File]::Open($File.path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $form = [Net.Http.MultipartFormDataContent]::new()
    try {
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
        if ($stream.Length -ne [long]$File.size -or $digest -cne $File.sha256) { throw 'Upload file changed after preparation; no attachment was sent.' }
        $stream.Position = 0
        $part = [Net.Http.StreamContent]::new($stream)
        $part.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
        $form.Add($part, 'file', [string]$File.filename)
        return ,(Invoke-JiraJson $Context 'POST' "issue/$IssueKey/attachments" $form)
    }
    finally { $form.Dispose(); $stream.Dispose() }
}

function Get-JiraAttachmentHash {
    param($Context, [string]$AttachmentId, [long]$ExpectedSize)
    if ($AttachmentId -cnotmatch '^[0-9]+$' -or $ExpectedSize -lt 0) { throw 'Invalid attachment metadata.' }
    $response = Send-JiraHttp $Context 'GET' "attachment/content/${AttachmentId}?redirect=false" $null -Stream
    $cts = [Threading.CancellationTokenSource]::new([timespan]::FromMinutes(5))
    $digest = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $stream = $null
    try {
        if ([int]$response.StatusCode -ne 200) { throw 'Attachment response is not a complete file.' }
        $stream = $response.Content.ReadAsStreamAsync($cts.Token).GetAwaiter().GetResult()
        $buffer = [byte[]]::new(65536)
        $size = 0L
        while (($read = $stream.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult()) -gt 0) {
            $size += $read
            if ($size -gt $ExpectedSize) { throw 'Attachment size changed during verification.' }
            $digest.AppendData($buffer, 0, $read)
        }
        if ($size -ne $ExpectedSize) { throw 'Attachment content is incomplete.' }
        return [Convert]::ToHexString($digest.GetHashAndReset()).ToLowerInvariant()
    }
    finally { if ($null -ne $stream) { $stream.Dispose() }; $digest.Dispose(); $cts.Dispose(); $response.Dispose() }
}

Export-ModuleMember -Function New-JiraContext, Invoke-JiraJson, Get-JiraPagedItems, Get-JiraProjects, Get-JiraIssue, Get-JiraComments, Get-JiraWorklogs, Get-JiraTransitions, Get-JiraCreateTypes, Get-JiraCreateFields, ConvertTo-JiraDocument, ConvertFrom-JiraDocument, Save-JiraAttachmentContent, Send-JiraAttachment, Get-JiraAttachmentHash
