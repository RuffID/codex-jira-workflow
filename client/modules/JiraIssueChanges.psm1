#requires -Version 7.5
Set-StrictMode -Version Latest

function ConvertTo-JiraCanonicalValue {
    param([AllowNull()]$Value, [switch]$NormalizeEmptyParagraphs)
    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) {
            # Jira omits content: [] when returning an empty paragraph.
            if ($NormalizeEmptyParagraphs -and $key -ceq 'content' -and $Value['type'] -ceq 'paragraph' -and $Value[$key] -is [array] -and $Value[$key].Count -eq 0) { continue }
            $ordered[$key] = ConvertTo-JiraCanonicalValue $Value[$key] -NormalizeEmptyParagraphs:$NormalizeEmptyParagraphs
        }
        return $ordered
    }
    if ($Value -is [array]) {
        $items = @(foreach ($item in $Value) { ConvertTo-JiraCanonicalValue $item -NormalizeEmptyParagraphs:$NormalizeEmptyParagraphs })
        return ,$items
    }
    return $Value
}

function Get-JiraValueHash {
    param([AllowNull()]$Value, [switch]$NormalizeEmptyParagraphs)
    return (Get-JiraHash (ConvertTo-Json -InputObject (ConvertTo-JiraCanonicalValue $Value -NormalizeEmptyParagraphs:$NormalizeEmptyParagraphs) -Depth 100 -Compress))
}

function Get-JiraDescriptionHash {
    param([AllowNull()]$Document)
    return (Get-JiraHash (ConvertTo-Json -InputObject (ConvertTo-JiraCanonicalValue $Document -NormalizeEmptyParagraphs) -Depth 100 -Compress))
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

function Get-JiraImageCommentAttachment {
    param($Issue, [string]$AttachmentId)
    if ($AttachmentId -cnotmatch '^[1-9][0-9]*\z') { throw 'attachmentId must be a positive numeric Jira attachment ID.' }
    $attachments = @($Issue.fields['attachment'] | Where-Object { $null -ne $_ })
    $selected = @($attachments | Where-Object { [string]$_['id'] -ceq $AttachmentId })
    if ($selected.Count -ne 1) { throw 'The selected attachment does not belong to this issue.' }
    $image = $selected[0]
    if ($image['mimeType'] -cnotin @('image/png', 'image/jpeg', 'image/gif', 'image/webp') -or $image['filename'] -notmatch '^[\p{L}\p{N}][\p{L}\p{N}._ -]*\.(png|jpe?g|gif|webp)\z') {
        throw 'Select a PNG, JPEG, GIF or WebP attachment with a filename safe for Jira wiki image markup.'
    }
    if (@($attachments | Where-Object { $_['filename'] -ieq $image['filename'] }).Count -ne 1) { throw 'The image filename must be unique on the issue.' }
    return @{ id = $AttachmentId; filename = [string]$image.filename; size = [long]$image.size; mimeType = [string]$image.mimeType }
}

function Get-JiraCommentImageBlocks {
    param($Document)
    if ($Document -isnot [Collections.IDictionary] -or $Document['type'] -cne 'doc') { return }
    foreach ($block in $Document['content']) {
        if ($null -eq $block -or $block['type'] -cne 'mediaSingle' -or $block['content'] -isnot [array] -or $block['content'].Count -ne 1) { continue }
        $media = $block['content'][0]
        if ($null -ne $media -and $media['type'] -ceq 'media' -and $media['attrs']['type'] -ceq 'file' -and $media['attrs']['id']) { $block }
    }
}

function New-JiraAdaptiveImageBlock {
    param($Block, [int]$Width, [int]$Height)
    $source = $Block['content'][0]['attrs']
    if ($Width -le 0 -or $Height -le 0 -or $source['collection'] -isnot [string]) { throw 'The image must have intrinsic dimensions and a Jira media collection.' }
    $media = @{ type = 'file'; id = $source['id']; collection = $source['collection']; alt = $source['alt']; width = $Width; height = $Height }
    return @{ type = 'mediaSingle'; attrs = @{ layout = 'align-start'; width = 100; widthType = 'percentage' }; content = @(@{ type = 'media'; attrs = $media }) }
}

function Get-JiraImageCommentSourceBlock {
    param($Context, [string]$IssueKey, $Image, [string]$SourceCommentId)
    if ($SourceCommentId -cnotmatch '^[1-9][0-9]*\z') { throw 'sourceCommentId must be a positive numeric Jira comment ID.' }
    $comments = Get-JiraComments $Context $IssueKey
    $source = @($comments | Where-Object { [string]$_['id'] -ceq $SourceCommentId })
    if ($source.Count -ne 1 -or [string]$source[0]['author']['accountId'] -cne $Context.accountId -or $source[0]['visibility'] -or $source[0]['jsdPublic'] -eq $false) {
        throw 'Select an unrestricted source comment you authored on the same issue.'
    }
    $blocks = @(Get-JiraCommentImageBlocks $source[0]['body'] | Where-Object { $_['content'][0]['attrs']['alt'] -ceq $Image.filename })
    if ($blocks.Count -ne 1) { throw 'The source comment must contain exactly one embedded image matching the attachment filename.' }
    $sourceBlock = $blocks[0]
    $sourceMedia = $sourceBlock['content'][0]['attrs']
    if (-not $sourceBlock['attrs']['layout'] -or $sourceMedia['collection'] -isnot [string]) { throw 'The source media block is missing layout or collection metadata.' }
    $layout = @{ layout = $sourceBlock['attrs']['layout'] }
    foreach ($field in 'width', 'widthType') {
        if ($sourceBlock['attrs'].Contains($field)) { $layout[$field] = $sourceBlock['attrs'][$field] }
    }
    # Reuse the Jira media reference and display settings without copying editor-local IDs.
    $media = @{ type = 'file'; id = $sourceMedia['id']; collection = $sourceMedia['collection']; alt = $Image.filename }
    foreach ($field in 'width', 'height') {
        if ($sourceMedia.Contains($field)) { $media[$field] = $sourceMedia[$field] }
    }
    return @{ type = 'mediaSingle'; attrs = $layout; content = @(@{ type = 'media'; attrs = $media }) }
}

function Get-JiraImageCommentResult {
    param($Context, [string]$IssueKey, $Step, [string]$OperationId, [string]$CommentId = '')
    $marker = "Операция: $OperationId"
    $comments = Get-JiraComments $Context $IssueKey
    $found = @($comments | Where-Object { (ConvertFrom-JiraDocument $_['body']) -csplit '\r?\n' -ccontains $marker })
    if ($found.Count -ne 1 -or [string]$found[0].author.accountId -cne $Context.accountId -or ($CommentId -and [string]$found[0].id -cne $CommentId)) { return $null }
    $body = $found[0].body
    $blocks = @(Get-JiraCommentImageBlocks $body)
    $inline = $blocks.Count -eq 1 -and (ConvertFrom-JiraDocument $body).Trim() -ceq $marker
    $result = @{ commentId = [string]$found[0].id; inlineImages = $false }
    if ($inline) {
        $actualMedia = $blocks[0]['content'][0]['attrs']
        $result.inlineImages = -not $actualMedia['alt'] -or $actualMedia['alt'] -ceq $Step.image.filename
    }
    if ($Step.Contains('imageBlock')) {
        $expected = $Step.imageBlock
        $result.layoutMatched = $result.inlineImages -and $actualMedia['id'] -ceq $expected.content[0].attrs.id -and
            $blocks[0]['attrs']['layout'] -ceq $expected.attrs['layout'] -and
            $blocks[0]['attrs']['widthType'] -ceq $expected.attrs['widthType'] -and
            $blocks[0]['attrs']['width'] -eq $expected.attrs['width'] -and
            $actualMedia['width'] -eq $expected.content[0].attrs['width'] -and
            $actualMedia['height'] -eq $expected.content[0].attrs['height']
    }
    return $result
}

function Get-JiraUploadFiles {
    param([Collections.IDictionary]$InputData)
    if (-not $InputData.Contains('files') -or $InputData.files -isnot [array] -or $InputData.files.Count -eq 0) { throw 'files must be a nonempty JSON array of absolute file paths.' }
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

function Set-JiraInlineUploadDimensions {
    param([array]$Files)
    if (@($Files.filename | Sort-Object -Unique).Count -ne $Files.Count) { throw 'Each inline image must have a unique filename.' }
    foreach ($file in $Files) {
        if ($file.filename -notmatch '^[\p{L}\p{N}][\p{L}\p{N}._ -]*\.(png|jpe?g|gif)\z') { throw 'New inline images must be PNG, JPEG or GIF with a filename safe for Jira wiki markup.' }
        $stream = [IO.File]::OpenRead($file.path)
        try {
            $image = [Drawing.Image]::FromStream($stream, $false, $true)
            try {
                $format = switch ([IO.Path]::GetExtension($file.filename).ToLowerInvariant()) {
                    '.png' { [Drawing.Imaging.ImageFormat]::Png }
                    '.gif' { [Drawing.Imaging.ImageFormat]::Gif }
                    default { [Drawing.Imaging.ImageFormat]::Jpeg }
                }
                if ($image.RawFormat.Guid -ne $format.Guid) { throw 'The image format does not match the filename.' }
                $file.width = $image.Width
                $file.height = $image.Height
            } finally { $image.Dispose() }
        } finally { $stream.Dispose() }
    }
}

function Get-JiraResolvedDescriptionImages {
    param($Description, [array]$Files, [string]$Marker)
    if ($Description -isnot [Collections.IDictionary] -or $Description['type'] -cne 'doc' -or $Description['version'] -ne 1 -or (ConvertFrom-JiraDocument $Description).Trim() -cne $Marker) { return $null }
    $blocks = @(Get-JiraCommentImageBlocks $Description)
    if ($Files.Count -eq 0 -or $blocks.Count -ne $Files.Count) { return $null }
    foreach ($node in $Description.content) {
        if ($node['type'] -ceq 'mediaSingle') { continue }
        if ($node['type'] -cne 'paragraph' -or @($node['content'] | Where-Object { $null -ne $_ -and $_['type'] -cne 'text' }).Count) { return $null }
    }
    $ids = [Collections.Generic.HashSet[guid]]::new()
    $images = @(for ($i = 0; $i -lt $Files.Count; $i++) {
        $media = $blocks[$i]['content'][0]['attrs']
        $mediaId = [guid]::Empty
        if (-not [guid]::TryParseExact([string]$media['id'], 'D', [ref]$mediaId) -or $mediaId -eq [guid]::Empty -or -not $ids.Add($mediaId) -or
            ($media['alt'] -and $media['alt'] -cne $Files[$i].filename) -or $media['collection'] -isnot [string]) { return $null }
        $image = New-JiraAdaptiveImageBlock $blocks[$i] $Files[$i].width $Files[$i].height
        $image.content[0].attrs.alt = $Files[$i].filename
        $image
    })
    return @{ descriptionHash = Get-JiraDescriptionHash $Description; images = $images }
}

function Get-JiraVerifiedInlineUploads {
    param($Issue, $Request, $Operation)
    for ($i = 0; $i -lt $Request.steps.Count; $i++) {
        if ($Request.steps[$i].kind -cne 'upload') { continue }
        $upload = $Operation.progress[$i]
        if ($upload.status -cne 'completed') { throw 'The image upload is not verified.' }
        $file = $Request.steps[$i].file
        $attachment = Get-JiraImageCommentAttachment $Issue $upload.result.attachmentId
        if ($attachment.filename -cne $file.filename -or $attachment.size -ne $file.size) { throw 'The uploaded image changed before description publication.' }
        $file
    }
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
    param($Context, $Binding, [string]$StatePath, [ValidateSet('create', 'link', 'attachments', 'description', 'comment', 'imageComment')][string]$Kind, [Collections.IDictionary]$InputData, [string]$OperationId = '')
    $id = if ($OperationId) { ([guid]::ParseExact($OperationId, 'D')).ToString('D') } else { [guid]::NewGuid().ToString('D') }
    $path = Get-JiraOperationPath $StatePath $id
    Assert-JiraPlainPath $path
    if ([IO.File]::Exists($path)) { throw 'Operation already exists; do not overwrite its journal record.' }
    $steps = [Collections.Generic.List[object]]::new()
    $key = ''
    $baseDescription = $null
    $attachmentInput = $null
    $files = @()
    $placement = $null
    $text = ''
    $links = @()
    $fields = $null
    $image = $null
    $imageBlock = $null
    $rendering = 'attachment-links'
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
        'description' {
            Assert-JiraInputKeys $InputData @('issueKey', 'text', 'attachmentId', 'resizeExisting')
            if ($InputData['text'] -isnot [string] -or [string]::IsNullOrWhiteSpace($InputData['text'])) { throw 'Description text must be a nonempty string.' }
            if ($InputData.Contains('resizeExisting') -and $InputData['resizeExisting'] -isnot [bool]) { throw 'resizeExisting must be a boolean.' }
            $resizeExisting = $InputData['resizeExisting'] -eq $true
            if ($resizeExisting -and -not $InputData.Contains('attachmentId')) { throw 'Specify attachmentId to resize an image below the supplied caption.' }
            $key = [string]$InputData['issueKey']
            $descriptionFields = @('project', 'description')
            if ($InputData.Contains('attachmentId')) { $descriptionFields += 'attachment' }
            $issue = Get-JiraChangeIssue $Context $Binding $key -Fields $descriptionFields
            $baseDescription = $issue.fields['description']
            Assert-JiraChangeDocument $baseDescription
            $placement = 'description'
            $text = $InputData.text
            $rendering = 'text'
            $descriptionStep = @{ kind = 'description'; text = $text; baseDescription = $baseDescription }
            if ($InputData.Contains('attachmentId')) {
                $image = Get-JiraImageCommentAttachment $issue ([string]$InputData['attachmentId'])
                $source = @(Get-JiraCommentImageBlocks $baseDescription | Where-Object { $_['content'][0]['attrs']['alt'] -ceq $image.filename })
                if ($resizeExisting) {
                    $caption = (ConvertTo-JiraDocument $text).content
                    $source = @($source | Where-Object {
                        $index = [array]::IndexOf($baseDescription.content, $_)
                        $index -ge $caption.Count -and (Get-JiraValueHash @($baseDescription.content[($index - $caption.Count)..($index - 1)]) -NormalizeEmptyParagraphs) -ceq
                            (Get-JiraValueHash $caption -NormalizeEmptyParagraphs)
                    })
                }
                if ($source.Count -ne 1) { throw 'The description must contain exactly one embedded block matching the selected image and any supplied caption for resizing.' }
                $media = $source[0]['content'][0]['attrs']
                $imageBlock = New-JiraAdaptiveImageBlock $source[0] ([int]$media['width']) ([int]$media['height'])
                $descriptionStep.image = $image
                $descriptionStep.sourceImageIndex = [array]::IndexOf($baseDescription.content, $source[0])
                if ($descriptionStep.sourceImageIndex -lt 0) { throw 'Could not locate the source image in the prepared description.' }
                if ($resizeExisting) {
                    $resized = @{} + $source[0]
                    $resized.attrs = @{} + $source[0]['attrs']
                    foreach ($field in $imageBlock.attrs.Keys) { $resized.attrs[$field] = $imageBlock.attrs[$field] }
                    $imageBlock = $resized
                    $descriptionStep.resizeExisting = $true
                }
                $descriptionStep.imageBlock = $imageBlock
                $rendering = 'adf-image'
            }
            $steps.Add($descriptionStep)
        }
        'comment' {
            Assert-JiraInputKeys $InputData @('issueKey', 'text')
            if ($InputData['text'] -isnot [string] -or [string]::IsNullOrWhiteSpace($InputData['text'])) { throw 'Comment text must be a nonempty string.' }
            $key = [string]$InputData['issueKey']
            [void](Get-JiraChangeIssue $Context $Binding $key -Fields @('project'))
            $placement = 'comment'
            $text = $InputData.text
            $rendering = 'text'
            $steps.Add(@{ kind = 'comment'; text = $text })
        }
        'imageComment' {
            Assert-JiraInputKeys $InputData @('issueKey', 'attachmentId', 'sourceCommentId')
            $key = [string]$InputData['issueKey']
            $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'attachment')
            $image = Get-JiraImageCommentAttachment $issue ([string]$InputData['attachmentId'])
            $placement = 'comment'
            $rendering = 'wiki-image'
            $imageStep = @{ kind = 'imageComment'; image = $image }
            if ($InputData.Contains('sourceCommentId')) {
                $imageStep.sourceCommentId = [string]$InputData['sourceCommentId']
                $imageBlock = Get-JiraImageCommentSourceBlock $Context $key $image $imageStep.sourceCommentId
                $imageStep.imageBlock = $imageBlock
                $rendering = 'adf-image'
            }
            $steps.Add($imageStep)
        }
    }
    if ($null -ne $attachmentInput) {
        $placement = if ($attachmentInput.Contains('placement')) { $attachmentInput.placement } elseif ($Kind -ceq 'create') { 'description' } else { 'comment' }
        if ($placement -cnotin @('description', 'comment')) { throw 'placement must be description or comment.' }
        $inlineUpload = $attachmentInput['rendering'] -ceq 'inline-images'
        if ($inlineUpload -and ($Kind -cne 'create' -or $placement -cne 'description')) { throw 'inline-images is available for the description of a newly created issue.' }
        if (-not $inlineUpload -and $attachmentInput['rendering'] -cne 'links') { throw 'Specify rendering=links or rendering=inline-images explicitly.' }
        $files = Get-JiraUploadFiles $attachmentInput
        Assert-JiraUploadSettings $Context $files
        if ($attachmentInput.Contains('text')) {
            if ($attachmentInput.text -isnot [string]) { throw 'Attachment text must be a string.' }
            $text = $attachmentInput.text
        }
        if ($placement -ceq 'description') { Assert-JiraChangeDocument $baseDescription }
        foreach ($file in $files) { $steps.Add(@{ kind = 'upload'; file = $file }) }
        $publish = @{ kind = $placement; text = $text; baseDescription = $baseDescription }
        if ($inlineUpload) {
            Set-JiraInlineUploadDimensions $files
            $rendering = 'inline-images'
            $marker = "Операция: $id"
            $initial = ConvertTo-JiraDocument $marker
            $initialFields = @{} + $fields
            $initialFields.description = $initial
            $steps[0].body.fields = $initialFields
            $publish.imagesFromStep = $steps.Count
            $steps.Add(@{ kind = 'resolveDescriptionImages'; initialDescription = $initial; marker = $marker })
        }
        $steps.Add($publish)
    }
    foreach ($link in $links) { $steps.Add(@{ kind = 'link'; link = $link }) }
    if ($steps.Count -eq 0) { throw 'The proposal contains no changes.' }
    $request = @{ kind = 'issueWorkflow'; issueKey = $key; steps = $steps.ToArray() }
    $requestJson = ConvertTo-Json -InputObject $request -Depth 100 -Compress
    $operation = @{
        schemaVersion = 1; id = $id; status = 'prepared'; createdAt = [datetimeoffset]::UtcNow.ToString('o'); completedAt = $null
        repositoryPath = $Binding.path; siteIdentity = $Context.siteIdentity; accountId = $Context.accountId
        requestJson = $requestJson; requestHash = Get-JiraHash $requestJson
        preview = @{ issueKey = $key; fields = $fields; links = $links; files = $files; placement = $placement; text = $text; rendering = $rendering; inlineImages = $false; descriptionMode = $(if ($Kind -cin @('comment', 'imageComment')) { $null } elseif ($steps[0].Contains('resizeExisting')) { 'resize-image' } else { 'append' }); steps = @($steps | ForEach-Object { $_.kind }) }
        progress = @($steps | ForEach-Object { @{ status = 'pending'; result = $null; beforeAttachmentIds = @(); expectedDocument = $null } })
        result = $null
    }
    if ($null -ne $image) { $operation.preview.image = $image }
    if ($null -ne $imageBlock) {
        $operation.preview.imageLayout = $imageBlock.attrs
        if ($Kind -ceq 'imageComment') { $operation.preview.sourceCommentId = $imageStep.sourceCommentId }
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
    if ($Step.kind -ceq 'description' -and $Step.Contains('sourceImageIndex')) {
        $original = $Step.baseDescription.content
        $content = @(for ($i = 0; $i -lt $original.Count; $i++) {
            if ($i -eq $Step.sourceImageIndex -and $Step.Contains('resizeExisting')) {
                $Step.imageBlock
                continue
            }
            $original[$i]
            if ($i -eq $Step.sourceImageIndex) {
                (ConvertTo-JiraDocument $Step.text).content
                $Step.imageBlock
            }
        })
        return @{ type = 'doc'; version = 1; content = $content }
    }
    if ($Step.kind -ceq 'description' -and $null -ne $Step.baseDescription) { $content += @($Step.baseDescription.content) }
    if ($Step.text) { $content += @((ConvertTo-JiraDocument $Step.text).content) }
    if ($Step.Contains('imagesFromStep')) {
        $resolved = $Operation.progress[$Step.imagesFromStep]
        if ($resolved.status -cne 'completed') { throw 'Jira image references have not been verified.' }
        return @{ type = 'doc'; version = 1; content = $content + @($resolved.result.images) }
    }
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
    if ($Request.steps[0].kind -ceq 'imageComment') {
        $imageResult = $Operation.progress[0].result
        $result = @{ issueKey = $key; url = "$($Context.siteUrl)/browse/$key"; steps = $Operation.progress; rendering = 'wiki-image'; inlineImages = $imageResult.inlineImages }
        if ($Request.steps[0].Contains('imageBlock')) {
            $result.rendering = 'adf-image'
            $result.layoutMatched = $imageResult.layoutMatched
        }
        return (Complete-JiraOperation $StatePath $Operation $result)
    }
    if ($Request.steps[0].Contains('sourceImageIndex')) {
        return (Complete-JiraOperation $StatePath $Operation @{ issueKey = $key; url = "$($Context.siteUrl)/browse/$key"; steps = $Operation.progress; rendering = 'adf-image'; inlineImages = $true })
    }
    if (@($Request.steps | Where-Object { $_.Contains('imagesFromStep') }).Count) {
        return (Complete-JiraOperation $StatePath $Operation @{ issueKey = $key; url = "$($Context.siteUrl)/browse/$key"; steps = $Operation.progress; rendering = 'inline-images'; inlineImages = $true })
    }
    $rendering = if ($Request.steps.Count -eq 1 -and $Request.steps[0].kind -cin @('description', 'comment')) { 'text' } else { 'attachment-links' }
    return (Complete-JiraOperation $StatePath $Operation @{ issueKey = $key; url = "$($Context.siteUrl)/browse/$key"; steps = $Operation.progress; rendering = $rendering; inlineImages = $false })
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
            if ($step.kind -ceq 'description' -and $Operation.progress[$i].status -cne 'completed' -and (Get-JiraDescriptionHash $current.fields['description']) -cne (Get-JiraDescriptionHash $step.baseDescription)) { throw 'Description changed after preparation; no further mutation was sent. Prepare and review a new append operation.' }
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
        $wikiComment = $false
        $wikiDescription = $false
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
            'imageComment' {
                $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'attachment')
                $image = Get-JiraImageCommentAttachment $issue $step.image.id
                if ((Get-JiraValueHash $image) -cne (Get-JiraValueHash $step.image)) { throw 'The selected image changed after preparation; no comment was sent.' }
                $marker = "Операция: $($Operation.id)"
                if ($step.Contains('imageBlock')) {
                    $sourceBlock = Get-JiraImageCommentSourceBlock $Context $key $image $step.sourceCommentId
                    if ((Get-JiraValueHash $sourceBlock) -cne (Get-JiraValueHash $step.imageBlock)) { throw 'The source image layout changed after preparation; no comment was sent.' }
                    $document = ConvertTo-JiraDocument $marker
                    $document.content = @($step.imageBlock) + $document.content
                    $body = @{ body = $document }
                } else {
                    $body = @{ body = "!$($image.filename)!`n`n$marker" }
                    $wikiComment = $true
                }
                $resource = "issue/$key/comment"
            }
            'resolveDescriptionImages' {
                $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'description', 'attachment')
                if ((Get-JiraDescriptionHash $issue.fields['description']) -cne (Get-JiraDescriptionHash $step.initialDescription)) { throw 'The initial description changed; image resolution was not sent.' }
                $uploads = @(Get-JiraVerifiedInlineUploads $issue $Request $Operation)
                $references = @($uploads | ForEach-Object { '!{0}|alt="{0}"!' -f $_.filename })
                $body = @{ fields = @{ description = ((@($step.marker) + $references) -join "`n`n") } }
                $method = 'PUT'; $resource = "issue/$key"; $wikiDescription = $true
            }
            'description' {
                $descriptionFields = @('project', 'description')
                if ($step.Contains('image')) { $descriptionFields += 'attachment' }
                $issue = Get-JiraChangeIssue $Context $Binding $key -Fields $descriptionFields
                $expectedHash = if ($step.Contains('imagesFromStep')) { $Operation.progress[$step.imagesFromStep].result.descriptionHash } else { Get-JiraDescriptionHash $step.baseDescription }
                if ((Get-JiraDescriptionHash $issue.fields['description']) -cne $expectedHash) { throw 'Description changed after preparation; existing content was not overwritten.' }
                if ($step.Contains('image') -and (Get-JiraValueHash (Get-JiraImageCommentAttachment $issue $step.image.id)) -cne (Get-JiraValueHash $step.image)) { throw 'The selected image changed after preparation; the description was not updated.' }
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
            $response = if ($step.kind -ceq 'upload') { Send-JiraAttachment $Context $key $step.file } else { Invoke-JiraJson $Context $method $resource $body -WikiComment:$wikiComment -WikiDescription:$wikiDescription }
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
                'imageComment' {
                    if (-not $response -or -not $response['id']) { throw 'Comment ID was not returned.' }
                    $result = Get-JiraImageCommentResult $Context $key $step $Operation.id ([string]$response.id)
                    if ($null -eq $result) { throw 'The new image comment could not be verified.' }
                }
                'resolveDescriptionImages' {
                    $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'description', 'attachment')
                    $uploads = @(Get-JiraVerifiedInlineUploads $issue $Request $Operation)
                    $result = Get-JiraResolvedDescriptionImages $issue.fields['description'] $uploads $step.marker
                    if ($null -eq $result) { throw 'Jira did not return valid embedded images for the uploaded files.' }
                }
                'link' {
                    $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'issuelinks')
                    $found = @(Get-JiraObservedLink $issue $step.link)
                    if ($found.Count -eq 0) { throw 'Link request was accepted but the link was not observed.' }
                    $result = @{ linkId = [string]$found[0].id; mode = 'link-observed' }
                }
                'description' {
                    $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'description')
                    if ((Get-JiraDescriptionHash $issue.fields['description']) -cne (Get-JiraDescriptionHash $progress.expectedDocument)) { throw 'The expected description was not observed after the update.' }
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
            if ((Get-JiraDescriptionHash $issue.fields['description']) -ceq (Get-JiraDescriptionHash $progress.expectedDocument)) { $result = @{ mode = 'description-observed' } }
        }
        'comment' {
            [void](Get-JiraChangeIssue $Context $Binding $key -Fields @('project'))
            $comments = Get-JiraComments $Context $key
            $marker = "Операция: $($Operation.id)"
            $found = @($comments | Where-Object { (ConvertFrom-JiraDocument $_['body']).Contains($marker) })
            if ($found.Count -eq 1 -and [string]$found[0].author.accountId -ceq $Context.accountId -and (Get-JiraValueHash $found[0].body -NormalizeEmptyParagraphs) -ceq (Get-JiraValueHash $progress.expectedDocument -NormalizeEmptyParagraphs)) { $result = @{ commentId = [string]$found[0].id; mode = 'comment-marker-verified' } }
        }
        'imageComment' {
            [void](Get-JiraChangeIssue $Context $Binding $key -Fields @('project'))
            $result = Get-JiraImageCommentResult $Context $key $step $Operation.id
        }
        'resolveDescriptionImages' {
            $issue = Get-JiraChangeIssue $Context $Binding $key -Fields @('project', 'description', 'attachment')
            $uploads = @(Get-JiraVerifiedInlineUploads $issue $Request $Operation)
            $result = Get-JiraResolvedDescriptionImages $issue.fields['description'] $uploads $step.marker
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
