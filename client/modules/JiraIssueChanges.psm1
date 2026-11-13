#requires -Version 7.5
Set-StrictMode -Version Latest

function ConvertTo-JiraCanonicalValue {
    param([AllowNull()]$Value)
    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) { $ordered[$key] = ConvertTo-JiraCanonicalValue $Value[$key] }
        return $ordered
    }
    if ($Value -is [array]) {
        $items = @(foreach ($item in $Value) { ConvertTo-JiraCanonicalValue $item })
        return ,$items
    }
    return $Value
}

function Get-JiraValueHash {
    param([AllowNull()]$Value)
    return (Get-JiraHash (ConvertTo-Json -InputObject (ConvertTo-JiraCanonicalValue $Value) -Depth 100 -Compress))
}

function Assert-JiraChangeDocument {
    param([AllowNull()]$Document)
    if ($null -ne $Document -and ($Document -isnot [Collections.IDictionary] -or $Document['type'] -cne 'doc' -or $Document['version'] -ne 1 -or $Document['content'] -isnot [array])) {
        throw 'Description must be a version 1 ADF document or null; existing rich content will not be flattened.'
    }
}

function Get-JiraChangeIssue {
    param($Context, $Binding, [string]$IssueKey, [string[]]$Fields = @('project', 'summary', 'attachment', 'description', 'issuelinks'))
    Assert-JiraAllowedIssue $Binding $IssueKey
    $issue = Get-JiraIssue $Context $IssueKey -Fields $Fields
    Assert-JiraIssueScope $Binding $IssueKey $issue
    return $issue
}

function Get-JiraUploadFiles {
    param([Collections.IDictionary]$InputData)
    if (-not $InputData.Contains('files') -or $InputData.files -isnot [array] -or $InputData.files.Count -eq 0) { throw 'files must be a nonempty JSON array of absolute file paths.' }
    if ($InputData['rendering'] -cne 'links') { throw 'Specify rendering=links explicitly. Inline media is unavailable through the supported public v3 attachment API; do not silently replace requested inline images with links.' }
    $files = @(
        foreach ($path in $InputData.files) {
            if ($path -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($path)) { throw 'Every upload path must be an absolute local file path.' }
            $fullPath = [IO.Path]::GetFullPath($path)
            Assert-JiraPlainPath $fullPath
            if (-not [IO.File]::Exists($fullPath)) { throw "Upload file does not exist: $fullPath" }
            $name = [IO.Path]::GetFileName($fullPath)
            if ($name -match '[\x00-\x1f]') { throw 'Invalid attachment filename.' }
            @{ path = $fullPath; filename = $name; size = ([IO.FileInfo]::new($fullPath)).Length; sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
    )
    if (@($files.path | Sort-Object -Unique).Count -ne $files.Count) { throw 'Duplicate upload paths are not allowed.' }
    return ,$files
}

function Assert-JiraUploadSettings {
    param($Context, [array]$Files)
    if ($Files.Count -eq 0) { return }
    $settings = Invoke-JiraJson $Context 'GET' 'attachment/meta'
    if ($settings['enabled'] -ne $true -or -not $settings.Contains('uploadLimit')) { throw 'Jira attachments are disabled or settings are incomplete.' }
    foreach ($file in $Files) {
        Assert-JiraPlainPath $file.path
        if (-not [IO.File]::Exists($file.path) -or ([IO.FileInfo]::new($file.path)).Length -ne [long]$file.size -or (Get-FileHash -LiteralPath $file.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256) { throw 'An upload file changed after preparation; prepare and review a new operation.' }
        if ([long]$file.size -gt [long]$settings.uploadLimit) { throw "File exceeds Jira uploadLimit: $($file.filename)" }
    }
}

function Get-JiraPreparedLinks {
    param($Context, $Binding, [AllowNull()]$Links, [string]$IssueKey)
    if ($null -eq $Links) { return ,@() }
    if ($Links -isnot [array] -or $Links.Count -eq 0) { throw 'links must be a nonempty JSON array.' }
    # Scope is checked for every endpoint before looking up types or issue data.
    foreach ($link in $Links) {
        if ($link -isnot [Collections.IDictionary]) { throw 'Each link must be a JSON object.' }
        Assert-JiraInputKeys $link @('issueKey', 'typeId', 'direction')
        Assert-JiraAllowedIssue $Binding ([string]$link['issueKey'])
        if ($link['issueKey'] -ceq $IssueKey) { throw 'An issue cannot be linked to itself.' }
        if ([string]$link['typeId'] -cnotmatch '^[0-9]+$' -or $link['direction'] -cnotin @('inward', 'outward')) { throw 'A link requires typeId and direction=inward|outward relative to the main issue.' }
    }
    $types = Invoke-JiraJson $Context 'GET' 'issueLinkType'
    $prepared = @(
        foreach ($link in $Links) {
            $selected = @($types.issueLinkTypes | Where-Object { [string]$_['id'] -ceq [string]$link.typeId })
            if ($selected.Count -ne 1) { throw 'The selected issue link type is unavailable.' }
            $type = $selected[0]
            [void](Get-JiraChangeIssue $Context $Binding $link.issueKey -Fields @('project'))
            @{ issueKey = [string]$link.issueKey; direction = [string]$link.direction; type = @{ id = [string]$type.id; name = [string]$type.name; inward = [string]$type.inward; outward = [string]$type.outward } }
        }
    )
    $identities = @($prepared | ForEach-Object { "$($_.issueKey)|$($_.type.id)|$($_.direction)" })
    if (@($identities | Sort-Object -Unique).Count -ne $prepared.Count) { throw 'Duplicate links in the same proposal are not allowed.' }
    return ,$prepared
}

function New-JiraIssueWorkflowProposal {
    param($Context, $Binding, [string]$StatePath, [ValidateSet('create', 'link', 'attachments')][string]$Kind, [Collections.IDictionary]$InputData, [string]$OperationId = '')
    $id = if ($OperationId) { ([guid]::ParseExact($OperationId, 'D')).ToString('D') } else { [guid]::NewGuid().ToString('D') }
    $path = Get-JiraOperationPath $StatePath $id
    Assert-JiraPlainPath $path
    if ([IO.File]::Exists($path)) { throw 'Operation already exists; do not overwrite its journal record.' }
    $steps = [Collections.Generic.List[object]]::new()
    $key = ''
    $baseDescription = $null
    $attachmentInput = $null
    $links = @()
    $fields = $null
    switch ($Kind) {
        'create' {
            Assert-JiraInputKeys $InputData @('fields', 'links', 'attachments')
            if ($InputData['fields'] -isnot [Collections.IDictionary]) { throw 'Create fields must be a JSON object.' }
            $fields = $InputData.fields
            if ($fields.Contains('description') -and $fields.description -is [string]) { $fields.description = ConvertTo-JiraDocument $fields.description }
            Assert-JiraCreatePayload $Context $Binding $fields
            $baseDescription = $fields['description']
            $steps.Add(@{ kind = 'create'; body = @{ fields = $fields; properties = @(@{ key = 'codex.operation'; value = @{ id = $id; source = 'Codex' } }) } })
            $links = Get-JiraPreparedLinks $Context $Binding $InputData['links'] ''
            if ($InputData.Contains('attachments')) {
                if ($InputData.attachments -isnot [Collections.IDictionary]) { throw 'attachments must be a JSON object.' }
                $attachmentInput = $InputData.attachments
                Assert-JiraInputKeys $attachmentInput @('files', 'placement', 'text', 'rendering')
            }
        }
        'link' {
            Assert-JiraInputKeys $InputData @('issueKey', 'links')
            $key = [string]$InputData['issueKey']
            [void](Get-JiraChangeIssue $Context $Binding $key -Fields @('project'))
            if (-not $InputData.Contains('links')) { throw 'links is required.' }
            $links = Get-JiraPreparedLinks $Context $Binding $InputData.links $key
        }
        'attachments' {
            Assert-JiraInputKeys $InputData @('issueKey', 'files', 'placement', 'text', 'rendering')
            $key = [string]$InputData['issueKey']
            $issue = Get-JiraChangeIssue $Context $Binding $key
            $baseDescription = $issue.fields['description']
            $attachmentInput = $InputData
        }
    }
    $files = @()
    $placement = $null
    $text = ''
    if ($null -ne $attachmentInput) {
        $files = Get-JiraUploadFiles $attachmentInput
        Assert-JiraUploadSettings $Context $files
        $placement = if ($attachmentInput.Contains('placement')) { $attachmentInput.placement } elseif ($Kind -ceq 'create') { 'description' } else { 'comment' }
        if ($placement -cnotin @('description', 'comment')) { throw 'placement must be description or comment.' }
        if ($attachmentInput.Contains('text')) {
            if ($attachmentInput.text -isnot [string]) { throw 'Attachment text must be a string.' }
            $text = $attachmentInput.text
        }
        if ($placement -ceq 'description') { Assert-JiraChangeDocument $baseDescription }
        foreach ($file in $files) { $steps.Add(@{ kind = 'upload'; file = $file }) }
        $steps.Add(@{ kind = $placement; text = $text; baseDescription = $baseDescription })
    }
    foreach ($link in $links) { $steps.Add(@{ kind = 'link'; link = $link }) }
    if ($steps.Count -eq 0) { throw 'The proposal contains no changes.' }
    $request = @{ kind = 'issueWorkflow'; issueKey = $key; steps = $steps.ToArray() }
    $requestJson = ConvertTo-Json -InputObject $request -Depth 100 -Compress
    $operation = @{
        schemaVersion = 1; id = $id; status = 'prepared'; createdAt = [datetimeoffset]::UtcNow.ToString('o'); completedAt = $null
        repositoryPath = $Binding.path; siteIdentity = $Context.siteIdentity; accountId = $Context.accountId
        requestJson = $requestJson; requestHash = Get-JiraHash $requestJson
        preview = @{ issueKey = $key; fields = $fields; links = $links; files = $files; placement = $placement; text = $text; rendering = 'attachment-links'; inlineImages = $false; descriptionMode = 'append'; steps = @($steps | ForEach-Object { $_.kind }) }
        progress = @($steps | ForEach-Object { @{ status = 'pending'; result = $null; beforeAttachmentIds = @(); expectedDocument = $null } })
        result = $null
    }
    Save-JiraOperation $StatePath $operation
    return $operation
}

function Get-JiraWorkflowKey {
    param($Request, $Operation)
    if ($Request.issueKey) { return [string]$Request.issueKey }
    for ($i = 0; $i -lt $Request.steps.Count; $i++) {
        if ($Request.steps[$i].kind -ceq 'create' -and $Operation.progress[$i].status -ceq 'completed') { return [string]$Operation.progress[$i].result.issueKey }
    }
    throw 'The issue creation step is not verified.'
}

function Get-JiraObservedLink {
    param($Issue, $Link)
    $field = $Link.direction + 'Issue'
    $otherField = if ($field -ceq 'outwardIssue') { 'inwardIssue' } else { 'outwardIssue' }
    return @($Issue.fields['issuelinks'] | Where-Object {
        $null -ne $_ -and [string]$_['type']['id'] -ceq $Link.type.id -and
        (($_.Contains($field) -and [string]$_[$field]['key'] -ceq $Link.issueKey) -or
        ($Link.type.inward -ceq $Link.type.outward -and $_.Contains($otherField) -and [string]$_[$otherField]['key'] -ceq $Link.issueKey))
    })
}

function New-JiraAttachmentDocument {
    param($Context, $Request, $Operation, $Step)
    $content = @()
    if ($Step.kind -ceq 'description' -and $null -ne $Step.baseDescription) { $content += @($Step.baseDescription.content) }
    if ($Step.text) { $content += @((ConvertTo-JiraDocument $Step.text).content) }
    for ($i = 0; $i -lt $Request.steps.Count; $i++) {
        if ($Request.steps[$i].kind -cne 'upload') { continue }
        $progress = $Operation.progress[$i]
        if ($progress.status -cne 'completed') { throw 'Attachment is not verified; no description or comment was sent.' }
        $file = $Request.steps[$i].file
        $url = "$($Context.siteUrl)/rest/api/3/attachment/content/$($progress.result.attachmentId)"
        $content += @{ type = 'paragraph'; content = @(@{ type = 'text'; text = $file.filename; marks = @(@{ type = 'link'; attrs = @{ href = $url } }) }) }
    }
    if ($Step.kind -ceq 'comment') { $content += @((ConvertTo-JiraDocument "Операция: $($Operation.id)").content) }
    return @{ type = 'doc'; version = 1; content = $content }
}

function Set-JiraWorkflowStepComplete {
    param([string]$StatePath, $Operation, [int]$Index, $Result)
    $Operation.progress[$Index].status = 'completed'
    $Operation.progress[$Index].result = $Result
    $Operation.status = 'partial'
    $Operation.result = @{ message = 'Verified steps are retained; remaining steps require Execute with the same reviewed hash.' }
    Save-JiraOperation $StatePath $Operation
}

function Complete-JiraWorkflow {
    param($Context, [string]$StatePath, $Operation, $Request)
    $key = Get-JiraWorkflowKey $Request $Operation
    return (Complete-JiraOperation $StatePath $Operation @{ issueKey = $key; url = "$($Context.siteUrl)/browse/$key"; steps = $Operation.progress; rendering = 'attachment-links'; inlineImages = $false })
}

function Invoke-JiraIssueWorkflow {
    param($Context, $Binding, [string]$StatePath, $Operation, $Request)
    if ($Operation.status -cnotin @('prepared', 'partial')) { throw 'Workflow requires reconciliation before continuing.' }
    if ($Operation.progress.Count -ne $Request.steps.Count) { throw 'Workflow journal is incomplete.' }
    # Preflight every pending upload before creation or any additional mutation.
    $files = @(for ($i = 0; $i -lt $Request.steps.Count; $i++) { if ($Request.steps[$i].kind -ceq 'upload' -and $Operation.progress[$i].status -cne 'completed') { $Request.steps[$i].file } })
    Assert-JiraUploadSettings $Context $files
    if ($Request.issueKey) {
        $current = Get-JiraChangeIssue $Context $Binding $Request.issueKey
        for ($i = 0; $i -lt $Request.steps.Count; $i++) {
            $step = $Request.steps[$i]
            if ($step.kind -ceq 'description' -and $Operation.progress[$i].status -cne 'completed' -and (Get-JiraValueHash $current.fields['description']) -cne (Get-JiraValueHash $step.baseDescription)) { throw 'Description changed after preparation; no further mutation was sent. Prepare and review a new append operation.' }
        }
    }
    foreach ($step in $Request.steps) {
        if ($step.kind -ceq 'link') { [void](Get-JiraChangeIssue $Context $Binding $step.link.issueKey -Fields @('project')) }
    }
    :workflowSteps for ($i = 0; $i -lt $Request.steps.Count; $i++) {
        $step = $Request.steps[$i]
        $progress = $Operation.progress[$i]
        if ($progress.status -ceq 'completed') { continue }
        if ($progress.status -cne 'pending') { throw 'An uncertain step cannot be resent; reconcile first.' }
        $key = if ($step.kind -ceq 'create') { '' } else { Get-JiraWorkflowKey $Request $Operation }
        $body = $null
        $resource = ''
        $method = 'POST'
        switch ($step.kind) {
            'create' { Assert-JiraCreatePayload $Context $Binding $step.body.fields; $body = $step.body; $resource = 'issue' }
            'link' {
                $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'issuelinks')
                [void](Get-JiraChangeIssue $Context $Binding $step.link.issueKey -Fields @('project'))
                if ($key -ceq $step.link.issueKey) { throw 'An issue cannot be linked to itself.' }
                $types = Invoke-JiraJson $Context 'GET' 'issueLinkType'
                $type = @($types.issueLinkTypes | Where-Object { [string]$_['id'] -ceq $step.link.type.id })
                if ($type.Count -ne 1 -or $type[0].name -cne $step.link.type.name -or $type[0].inward -cne $step.link.type.inward -or $type[0].outward -cne $step.link.type.outward) { throw 'Link type changed after preparation; review a new proposal.' }
                $found = @(Get-JiraObservedLink $issue $step.link)
                if ($found.Count -gt 0) { Set-JiraWorkflowStepComplete $StatePath $Operation $i @{ mode = 'link-already-present'; linkId = $found[0].id }; continue workflowSteps }
                # direction is the label displayed on the main issue, as in its issuelinks field.
                $body = @{ type = @{ id = $step.link.type.id } }
                $body[$step.link.direction + 'Issue'] = @{ key = $step.link.issueKey }
                $other = if ($step.link.direction -ceq 'outward') { 'inwardIssue' } else { 'outwardIssue' }
                $body[$other] = @{ key = $key }
                $resource = 'issueLink'
            }
            'upload' {
                $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'attachment')
                $progress.beforeAttachmentIds = @($issue.fields['attachment'] | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.id })
                $resource = "issue/$key/attachments"
            }
            'comment' {
                [void](Get-JiraChangeIssue $Context $Binding $key -Fields @('project'))
                $progress.expectedDocument = New-JiraAttachmentDocument $Context $Request $Operation $step
                $body = @{ body = $progress.expectedDocument }
                $resource = "issue/$key/comment"
            }
            'description' {
                $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'description')
                if ((Get-JiraValueHash $issue.fields['description']) -cne (Get-JiraValueHash $step.baseDescription)) { throw 'Description changed after preparation; existing content was not overwritten.' }
                $progress.expectedDocument = New-JiraAttachmentDocument $Context $Request $Operation $step
                $body = @{ fields = @{ description = $progress.expectedDocument } }
                $method = 'PUT'; $resource = "issue/$key"
            }
            default { throw 'Unsupported workflow step.' }
        }
        $Operation.status = 'sending'; $progress.status = 'sending'
        Save-JiraOperation $StatePath $Operation
        $accepted = $false
        try {
            $response = if ($step.kind -ceq 'upload') { Send-JiraAttachment $Context $key $step.file } else { Invoke-JiraJson $Context $method $resource $body }
            $accepted = $true
            switch ($step.kind) {
                'create' {
                    if (-not $response -or [string]$response['key'] -cnotmatch ('^' + [regex]::Escape([string]$step.body.fields.project.key) + '-[1-9][0-9]*$')) { throw 'Created issue key is missing or outside the selected project.' }
                    Assert-JiraAllowedIssue $Binding $response.key
                    $result = @{ issueKey = [string]$response.key }
                }
                'upload' {
                    $attachments = @($response)
                    if ($attachments.Count -ne 1 -or [string]$attachments[0]['id'] -cnotmatch '^[0-9]+$' -or $attachments[0]['filename'] -cne $step.file.filename -or [long]$attachments[0]['size'] -ne [long]$step.file.size) { throw 'Jira returned unexpected attachment metadata.' }
                    $result = @{ attachmentId = [string]$attachments[0].id; filename = $step.file.filename; sha256 = $step.file.sha256 }
                }
                'comment' {
                    if (-not $response -or -not $response['id']) { throw 'Comment ID was not returned.' }
                    $result = @{ commentId = [string]$response.id }
                }
                'link' {
                    $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'issuelinks')
                    $found = @(Get-JiraObservedLink $issue $step.link)
                    if ($found.Count -eq 0) { throw 'Link request was accepted but the link was not observed.' }
                    $result = @{ linkId = [string]$found[0].id; mode = 'link-observed' }
                }
                'description' {
                    $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'description')
                    if ((Get-JiraValueHash $issue.fields['description']) -cne (Get-JiraValueHash $progress.expectedDocument)) { throw 'The expected description was not observed after the update.' }
                    $result = @{ mode = 'description-observed' }
                }
            }
            Set-JiraWorkflowStepComplete $StatePath $Operation $i $result
        }
        catch {
            $exception = $_.Exception
            if (-not $accepted -and $exception.Data.Contains('DefinitelyRejected') -and $exception.Data['DefinitelyRejected']) { $progress.status = 'pending'; $Operation.status = 'partial' }
            else { $progress.status = 'unknown'; $Operation.status = 'unknown' }
            $Operation.result = @{ step = $i; kind = $step.kind; message = 'Workflow stopped. Completed steps are retained; an uncertain step must be reconciled.'; httpStatus = $exception.Data['JiraStatus'] }
            Save-JiraOperation $StatePath $Operation
            throw [InvalidOperationException]::new("Operation $($Operation.id) is $($Operation.status) at step $i ($($step.kind)): $($exception.Message) Inspect the journal before continuing.")
        }
    }
    return (Complete-JiraWorkflow $Context $StatePath $Operation $Request)
}

function Sync-JiraIssueWorkflow {
    param($Context, $Binding, [string]$StatePath, $Operation, $Request, [string]$ResultIssueKey = '')
    $uncertain = @(for ($i = 0; $i -lt $Request.steps.Count; $i++) { if ($Operation.progress[$i].status -cin @('sending', 'unknown')) { $i } })
    if ($uncertain.Count -ne 1) { throw 'Workflow must contain exactly one uncertain step to reconcile.' }
    $i = $uncertain[0]; $step = $Request.steps[$i]; $progress = $Operation.progress[$i]
    $Operation.status = 'unknown'; $progress.status = 'unknown'
    Save-JiraOperation $StatePath $Operation
    $key = if ($step.kind -ceq 'create') { $ResultIssueKey } else { Get-JiraWorkflowKey $Request $Operation }
    $result = $null
    switch ($step.kind) {
        'create' {
            if (-not $key) { throw 'Provide ResultIssueKey to verify the creation marker; creation cannot be repeated.' }
            $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project')
            if ($issue.fields.project.key -cne $step.body.fields.project.key) { throw 'Candidate issue belongs to a different project.' }
            $property = Invoke-JiraJson $Context 'GET' "issue/$key/properties/codex.operation"
            if ([string]$property['value']['id'] -ceq $Operation.id) { $result = @{ issueKey = $key; mode = 'creation-marker-verified' } }
        }
        'link' {
            $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'issuelinks')
            [void](Get-JiraChangeIssue $Context $Binding $step.link.issueKey -Fields @('project'))
            $found = @(Get-JiraObservedLink $issue $step.link)
            if ($found.Count -gt 0) { $result = @{ linkId = [string]$found[0].id; mode = 'link-observed' } }
        }
        'description' {
            $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'description')
            if ((Get-JiraValueHash $issue.fields['description']) -ceq (Get-JiraValueHash $progress.expectedDocument)) { $result = @{ mode = 'description-observed' } }
        }
        'comment' {
            [void](Get-JiraChangeIssue $Context $Binding $key -Fields @('project'))
            $comments = Get-JiraComments $Context $key
            $marker = "Операция: $($Operation.id)"
            $found = @($comments | Where-Object { (ConvertFrom-JiraDocument $_['body']).Contains($marker) })
            if ($found.Count -eq 1 -and [string]$found[0].author.accountId -ceq $Context.accountId -and (Get-JiraValueHash $found[0].body) -ceq (Get-JiraValueHash $progress.expectedDocument)) { $result = @{ commentId = [string]$found[0].id; mode = 'comment-marker-verified' } }
        }
        'upload' {
            $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'attachment')
            $candidates = @($issue.fields['attachment'] | Where-Object { $null -ne $_ -and [string]$_['id'] -cnotin $progress.beforeAttachmentIds -and $_['filename'] -ceq $step.file.filename -and [long]$_['size'] -eq [long]$step.file.size -and [string]$_['author']['accountId'] -ceq $Context.accountId })
            $found = @($candidates | Where-Object { (Get-JiraAttachmentHash $Context ([string]$_.id) ([long]$_.size)) -ceq $step.file.sha256 })
            if ($found.Count -eq 1) { $result = @{ attachmentId = [string]$found[0].id; filename = $step.file.filename; sha256 = $step.file.sha256; mode = 'content-hash-verified' } }
        }
        default { throw 'Unsupported workflow step.' }
    }
    if ($null -eq $result) {
        $Operation.result = @{ step = $i; kind = $step.kind; message = 'No unique matching result was verified. Do not resend or create a replacement operation automatically.' }
        Save-JiraOperation $StatePath $Operation
        return $Operation
    }
    Set-JiraWorkflowStepComplete $StatePath $Operation $i $result
    if (@($Operation.progress | Where-Object { $_.status -cne 'completed' }).Count -eq 0) { return (Complete-JiraWorkflow $Context $StatePath $Operation $Request) }
    return $Operation
}

Export-ModuleMember -Function New-JiraIssueWorkflowProposal, Invoke-JiraIssueWorkflow, Sync-JiraIssueWorkflow
