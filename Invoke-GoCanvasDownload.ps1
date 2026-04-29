<#
.SYNOPSIS
    Downloads all available goCanvas submission documents to a local directory.

.DESCRIPTION
    Connects to the goCanvas API v3, retrieves all available submissions across
    all forms/apps, and downloads each submission as a PDF. If a PDF is not
    available for a submission, BOTH the CSV and XML versions are downloaded
    instead. Already-downloaded files are skipped.

    Authentication uses OAuth 2.0 Client Credentials Flow. You must create an
    OAuth application in your goCanvas profile at
    https://www.gocanvas.com/my_api_settings and supply the resulting
    Client ID and Client Secret either in a .env file placed alongside the
    script (recommended) or directly in the CONFIGURATION section of this script.

    Downloaded files are named using the submission's reference id, name,
    user id and status (e.g. "REF001_Site_Inspection_42_complete.pdf").

    A per-form CSV index (`_submissions_index.csv`) is written to each form
    folder. It contains every field returned by the API for each submission,
    along with the resulting filename(s) and the download status.

.PARAMETER OutputPath
    The root folder where downloaded files are saved.
    Defaults to a "GoCanvasDownloads" folder in the current working directory.

.PARAMETER PageSize
    Number of submissions to request per API page. Defaults to 100 (the API maximum).

.EXAMPLE
    .\Invoke-GoCanvasDownload.ps1

.EXAMPLE
    .\Invoke-GoCanvasDownload.ps1 -OutputPath "C:\Downloads\GoCanvas"
#>

[CmdletBinding()]
param (
    [string]$OutputPath = (Join-Path (Get-Location) 'GoCanvasDownloads'),
    [int]$PageSize = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# CONFIGURATION — credentials can be supplied via a .env file placed in the
# same directory as this script (preferred) or by editing the fallback values
# below.  The .env file should contain lines in KEY=VALUE format:
#
#   GOCANVAS_CLIENT_ID=your_client_id
#   GOCANVAS_CLIENT_SECRET=your_client_secret
#
# Lines beginning with # and blank lines are ignored.
# Create an OAuth application at https://www.gocanvas.com/my_api_settings
# and use the Client Credentials flow (server-to-server).
# ---------------------------------------------------------------------------
$Script:ClientId     = 'YOUR_CLIENT_ID'
$Script:ClientSecret = 'YOUR_CLIENT_SECRET'

$_envFile = Join-Path $PSScriptRoot '.env'
if (Test-Path $_envFile) {
    Get-Content $_envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and $line -notmatch '^\s*#') {
            $parts = $line -split '=', 2
            if ($parts.Count -eq 2) {
                $key   = $parts[0].Trim()
                $value = $parts[1].Trim().Trim('"', "'")
                switch ($key) {
                    'GOCANVAS_CLIENT_ID'     { $Script:ClientId     = $value }
                    'GOCANVAS_CLIENT_SECRET' { $Script:ClientSecret = $value }
                }
            }
        }
    }
}
Remove-Variable -Name '_envFile'
# ---------------------------------------------------------------------------

$Script:V3BaseUrl = 'https://api.gocanvas.com/api/v3'

# Internal token cache — populated by Get-BearerToken on first use.
$Script:AccessToken  = $null
$Script:TokenExpiry  = [datetime]::MinValue

# Maximum length for a generated base filename (excluding extension).
$Script:MaxFileNameLength = 150

# Maximum nesting depth used when serialising nested API objects to JSON
# for inclusion in the submissions index CSV.
$Script:JsonSerializationDepth = 10

# Number of seconds before token expiry at which a fresh token is requested.
$Script:TokenRefreshBufferSeconds = 60

# Fallback per_page values tried (in order) when the API returns 422 on the
# first page of a form's submissions.  Some forms reject the default page size.
$Script:FallbackPageSizes = @(10, 1)

# ---------------------------------------------------------------------------
# Helper: obtain (and cache) an OAuth 2.0 Bearer token using the
# Client Credentials flow.  The token is reused until it is within
# 60 seconds of expiry, at which point a fresh one is requested.
# ---------------------------------------------------------------------------
function Get-BearerToken {
    $now = [datetime]::UtcNow

    if ($Script:AccessToken -and $now -lt $Script:TokenExpiry) {
        return $Script:AccessToken
    }

    $tokenUri = "$Script:V3BaseUrl/oauth/token"
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $Script:ClientId
        client_secret = $Script:ClientSecret
        scope         = 'api'
    }

    try {
        $response = Invoke-RestMethod -Uri $tokenUri -Method POST -Body $body `
                        -ContentType 'application/x-www-form-urlencoded'
    }
    catch [System.Net.WebException] {
        $statusCode = [int]$_.Exception.Response.StatusCode
        Write-Error "OAuth token request failed [$statusCode]: $tokenUri"
        throw
    }

    $Script:AccessToken = Get-ObjectProperty -Object $response -Name 'access_token'
    $rawExpiry = Get-ObjectProperty -Object $response -Name 'expires_in'
    $expiresIn = if ($rawExpiry) { [int]$rawExpiry } else { 3600 }
    # Subtract the buffer so we refresh before the token expires
    $Script:TokenExpiry = $now.AddSeconds($expiresIn - $Script:TokenRefreshBufferSeconds)

    return $Script:AccessToken
}

# ---------------------------------------------------------------------------
# Helper: invoke a goCanvas API request and return the parsed response
# ---------------------------------------------------------------------------
function Invoke-GoCanvasRequest {
    param (
        [string]$Uri,
        [string]$Method   = 'GET',
        [hashtable]$Query = @{}
    )

    $headers = @{
        Authorization = 'Bearer ' + (Get-BearerToken)
        Accept        = 'application/json'
    }

    if ($Query.Count -gt 0) {
        $queryString = ($Query.GetEnumerator() |
            ForEach-Object { '{0}={1}' -f [Uri]::EscapeDataString($_.Key), [Uri]::EscapeDataString($_.Value) }) -join '&'
        $Uri = '{0}?{1}' -f $Uri, $queryString
    }

    try {
        $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers
        return $response
    }
    catch [System.Net.WebException] {
        $statusCode = [int]$_.Exception.Response.StatusCode
        Write-Warning "API request failed [$statusCode]: $Uri"
        throw
    }
}

# ---------------------------------------------------------------------------
# Helper: download a binary file (PDF / CSV / XML)
# ---------------------------------------------------------------------------
function Invoke-GoCanvasFileDownload {
    param (
        [string]$Uri,
        [string]$OutFile
    )

    $headers = @{
        Authorization = 'Bearer ' + (Get-BearerToken)
        Accept        = '*/*'
    }

    try {
        Invoke-WebRequest -Uri $Uri -Headers $headers -OutFile $OutFile -UseBasicParsing
        return $true
    }
    catch [System.Net.WebException] {
        $statusCode = [int]$_.Exception.Response.StatusCode
        if ($statusCode -eq 404) {
            return $false   # format not available for this submission
        }
        Write-Warning "Download failed [$statusCode]: $Uri"
        return $false
    }
}

# ---------------------------------------------------------------------------
# Sanitise a string so it can be used as part of a file/folder name
# ---------------------------------------------------------------------------
function Get-SafeName {
    param ([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $re      = '[{0}]' -f [RegEx]::Escape($invalid)
    # Replace invalid chars and collapse runs of whitespace/underscores
    $clean   = ($Name -replace $re, '_') -replace '\s+', '_' -replace '_+', '_'
    $clean.Trim('_', ' ', '.')
}

# ---------------------------------------------------------------------------
# Safely read a named property from a PSCustomObject or hashtable returned by
# the API.  Unlike direct property access, this is safe under
# Set-StrictMode -Version Latest because it checks for existence first.
# Returns $null when the property is absent or its value is null/empty.
# ---------------------------------------------------------------------------
function Get-ObjectProperty {
    param (
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $null }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# ---------------------------------------------------------------------------
# Read a property from a submission object regardless of casing or whether the
# underlying object is a PSCustomObject or a hashtable.
# Returns $null when the property is missing/empty.
# ---------------------------------------------------------------------------
function Get-SubmissionProperty {
    param (
        [object]$Submission,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if ($null -eq $Submission) { continue }

        if ($Submission -is [System.Collections.IDictionary]) {
            if ($Submission.Contains($name) -and $null -ne $Submission[$name] -and "$($Submission[$name])" -ne '') {
                return $Submission[$name]
            }
        }
        else {
            $prop = $Submission.PSObject.Properties[$name]
            if ($prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') {
                return $prop.Value
            }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Build the on-disk base filename for a submission, including reference id,
# name, user id and status.  Returns a sanitised, length-capped string.
# ---------------------------------------------------------------------------
function Get-SubmissionBaseName {
    param ([object]$Submission)

    $id      = Get-SubmissionProperty -Submission $Submission -Names @('id','submission_id')
    $refId   = Get-SubmissionProperty -Submission $Submission -Names @('reference_id','referenceId')
    $name    = Get-SubmissionProperty -Submission $Submission -Names @('name','form_name','app_name','title')
    $userId  = Get-SubmissionProperty -Submission $Submission -Names @('user_id','userId','submitted_by_id','user')
    $status  = Get-SubmissionProperty -Submission $Submission -Names @('status','state','submission_status')

    if (-not $refId) { $refId = $id }

    $parts = @()
    if ($refId)  { $parts += [string]$refId }
    if ($name)   { $parts += [string]$name }
    if ($userId) { $parts += [string]$userId }
    if ($status) { $parts += [string]$status }

    # Always include something – fall back to the submission id
    if ($parts.Count -eq 0 -and $id) { $parts += [string]$id }

    $raw  = ($parts -join '_')
    $safe = Get-SafeName -Name $raw

    # Cap length to leave room for the extension within typical filesystem limits
    if ($safe.Length -gt $Script:MaxFileNameLength) {
        $safe = $safe.Substring(0, $Script:MaxFileNameLength).TrimEnd('_', ' ', '.')
    }

    if (-not $safe) { $safe = 'submission_' + [string]$id }
    return $safe
}

# ---------------------------------------------------------------------------
# Flatten a submission object into an ordered hashtable suitable for export
# to CSV.  Nested objects / arrays are serialised to JSON so that no data is
# lost.
# ---------------------------------------------------------------------------
function ConvertTo-FlatSubmissionRecord {
    param ([object]$Submission)

    $row = [ordered]@{}

    if ($null -eq $Submission) { return [pscustomobject]$row }

    if ($Submission -is [System.Collections.IDictionary]) {
        $properties = $Submission.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{ Name = $_.Key; Value = $_.Value }
        }
    }
    else {
        $properties = $Submission.PSObject.Properties | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Value = $_.Value }
        }
    }

    foreach ($p in $properties) {
        $value = $p.Value
        if ($null -eq $value) {
            $row[$p.Name] = ''
        }
        elseif ($value -is [string] -or $value -is [ValueType]) {
            $row[$p.Name] = $value
        }
        else {
            try {
                $row[$p.Name] = ($value | ConvertTo-Json -Depth $Script:JsonSerializationDepth -Compress)
            }
            catch {
                $row[$p.Name] = [string]$value
            }
        }
    }

    return [pscustomobject]$row
}

# ---------------------------------------------------------------------------
# Merge two arrays of column names, preserving the order of the first list
# and appending any new names from the second list.
# ---------------------------------------------------------------------------
function Merge-ColumnList {
    param (
        [string[]]$Existing,
        [string[]]$New
    )

    $seen   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[string]]::new()

    foreach ($c in $Existing) {
        if ($c -and $seen.Add($c)) { $result.Add($c) }
    }
    foreach ($c in $New) {
        if ($c -and $seen.Add($c)) { $result.Add($c) }
    }
    return $result.ToArray()
}

# ---------------------------------------------------------------------------
# Write the per-form submissions index CSV.  All rows are normalised to
# share the same columns (the union of every row's properties) so that
# Export-Csv produces a clean file even when individual submissions have
# different fields.
# ---------------------------------------------------------------------------
function Write-SubmissionsIndex {
    param (
        [string]$Path,
        [object[]]$Rows
    )

    if (-not $Rows -or $Rows.Count -eq 0) { return }

    # Build the union of all property names, preserving insertion order
    $columns = @()
    foreach ($row in $Rows) {
        $names = $row.PSObject.Properties | ForEach-Object { $_.Name }
        $columns = Merge-ColumnList -Existing $columns -New $names
    }

    # Project every row onto the full column set
    $normalised = foreach ($row in $Rows) {
        $obj = [ordered]@{}
        foreach ($c in $columns) {
            $prop = $row.PSObject.Properties[$c]
            $obj[$c] = if ($prop) { $prop.Value } else { '' }
        }
        [pscustomobject]$obj
    }

    $normalised | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Retrieve every page of submissions for a given form (app_id)
# Returns an array of submission objects
# ---------------------------------------------------------------------------
function Get-AllSubmissions {
    param ([string]$AppId)

    $allSubmissions = [System.Collections.Generic.List[object]]::new()
    $page           = 1
    $effectivePageSize = $PageSize

    do {
        $query = @{
            app_id   = $AppId
            page     = [string]$page
            per_page = [string]$effectivePageSize
        }

        try {
            $result = Invoke-GoCanvasRequest -Uri "$Script:V3BaseUrl/submissions" -Query $query
        }
        catch [System.Net.WebException] {
            $statusCode = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($statusCode -eq 422) {
                # Some forms reject the current page size.  When we are on page 1
                # (nothing collected yet) try progressively smaller per_page values
                # before giving up.  On later pages we have already succeeded with
                # the current page size, so 422 is likely a transient/data problem;
                # return whatever was collected rather than discarding it.
                if ($page -eq 1) {
                    $nextSize = $Script:FallbackPageSizes | Where-Object { $_ -lt $effectivePageSize } | Select-Object -First 1
                    if ($null -ne $nextSize) {
                        Write-Warning "  Form $AppId returned 422 with per_page=$effectivePageSize - retrying with per_page=$nextSize."
                        $effectivePageSize = $nextSize
                        continue
                    }
                }
                Write-Warning "  Form $AppId returned 422 (Unprocessable Entity) - skipping form (no accessible submissions or form is archived)."
                return $allSubmissions.ToArray()
            }
            throw
        }

        $rawSubs = Get-ObjectProperty -Object $result -Name 'submissions'
        $submissions = @(if ($rawSubs) { $rawSubs }
                         elseif ($result -is [array]) { $result }
                         else { @() })

        foreach ($sub in $submissions) {
            $allSubmissions.Add($sub)
        }

        # Determine whether there are more pages
        $rawTotal   = Get-ObjectProperty -Object $result -Name 'total_count'
        $total      = if ($rawTotal) { [int]$rawTotal } else { $allSubmissions.Count }
        $fetched    = $allSubmissions.Count
        $morePages  = $fetched -lt $total
        $page++

    } while ($morePages -and $submissions.Count -gt 0)

    return $allSubmissions.ToArray()
}

# ---------------------------------------------------------------------------
# Try to download a single format for a submission.
# Returns $true on success (file saved) and $false on failure / unavailable.
# If a file already exists on disk it is treated as success and not re-downloaded.
# ---------------------------------------------------------------------------
function Save-SubmissionFormat {
    param (
        [string]$SubmissionId,
        [string]$FormFolder,
        [string]$SafeName,
        [string]$Extension
    )

    $filePath = Join-Path $FormFolder ('{0}.{1}' -f $SafeName, $Extension)

    if (Test-Path $filePath) {
        Write-Verbose "  [SKIP] $filePath already exists."
        return $true
    }

    $downloadUri = '{0}/submissions/{1}.{2}' -f $Script:V3BaseUrl, $SubmissionId, $Extension
    Write-Verbose "  Trying $($Extension.ToUpper()): $downloadUri"

    $tmpFile = $filePath + '.tmp'
    $ok      = Invoke-GoCanvasFileDownload -Uri $downloadUri -OutFile $tmpFile

    if ($ok -and (Test-Path $tmpFile) -and (Get-Item $tmpFile).Length -gt 0) {
        Move-Item -Path $tmpFile -Destination $filePath
        Write-Verbose "  [OK]   Saved $filePath"
        return $true
    }

    # Remove incomplete temp file
    if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force }
    return $false
}

# ---------------------------------------------------------------------------
# Download one submission.
#   1. Try PDF first. If PDF succeeds -> done.
#   2. If PDF is unavailable, download BOTH CSV and XML.
# Returns an object describing what was saved:
#   @{ BaseName = 'REF_NAME_USER_STATUS'; Files = @('REF_….pdf'); Status = 'Downloaded' }
# Status is one of 'Downloaded', 'Skipped' (already on disk) or 'Failed'.
# ---------------------------------------------------------------------------
function Save-Submission {
    param (
        [object]$Submission,
        [string]$FormFolder
    )

    $submissionId = [string](Get-SubmissionProperty -Submission $Submission -Names @('id','submission_id'))
    $safeName     = Get-SubmissionBaseName -Submission $Submission

    $pdfPath = Join-Path $FormFolder ('{0}.pdf' -f $safeName)
    $csvPath = Join-Path $FormFolder ('{0}.csv' -f $safeName)
    $xmlPath = Join-Path $FormFolder ('{0}.xml' -f $safeName)

    # ---- Already on disk? ------------------------------------------------
    $pdfExists = Test-Path $pdfPath
    $csvExists = Test-Path $csvPath
    $xmlExists = Test-Path $xmlPath

    if ($pdfExists) {
        return [pscustomobject]@{
            BaseName = $safeName
            Files    = @([System.IO.Path]::GetFileName($pdfPath))
            Status   = 'Skipped'
        }
    }
    if ($csvExists -and $xmlExists) {
        return [pscustomobject]@{
            BaseName = $safeName
            Files    = @(
                [System.IO.Path]::GetFileName($csvPath),
                [System.IO.Path]::GetFileName($xmlPath)
            )
            Status   = 'Skipped'
        }
    }

    # ---- 1. Try PDF first ------------------------------------------------
    $pdfOk = Save-SubmissionFormat -SubmissionId $submissionId `
                                   -FormFolder   $FormFolder `
                                   -SafeName     $safeName `
                                   -Extension    'pdf'

    if ($pdfOk) {
        return [pscustomobject]@{
            BaseName = $safeName
            Files    = @([System.IO.Path]::GetFileName($pdfPath))
            Status   = 'Downloaded'
        }
    }

    # ---- 2. PDF failed -> download BOTH CSV and XML ----------------------
    $savedFiles = @()

    $csvOk = Save-SubmissionFormat -SubmissionId $submissionId `
                                   -FormFolder   $FormFolder `
                                   -SafeName     $safeName `
                                   -Extension    'csv'
    if ($csvOk) { $savedFiles += [System.IO.Path]::GetFileName($csvPath) }

    $xmlOk = Save-SubmissionFormat -SubmissionId $submissionId `
                                   -FormFolder   $FormFolder `
                                   -SafeName     $safeName `
                                   -Extension    'xml'
    if ($xmlOk) { $savedFiles += [System.IO.Path]::GetFileName($xmlPath) }

    if ($savedFiles.Count -gt 0) {
        return [pscustomobject]@{
            BaseName = $safeName
            Files    = $savedFiles
            Status   = 'Downloaded'
        }
    }

    Write-Warning "  [FAIL] Could not download submission $submissionId in any format."
    return [pscustomobject]@{
        BaseName = $safeName
        Files    = @()
        Status   = 'Failed'
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Invoke-Main {
    Write-Host "goCanvas Downloader" -ForegroundColor Cyan
    Write-Host "===================" -ForegroundColor Cyan
    Write-Host "Output folder : $OutputPath"
    Write-Host "API endpoint  : $Script:V3BaseUrl"
    Write-Host ""

    # Validate credentials are configured
    if ($Script:ClientId -eq 'YOUR_CLIENT_ID' -or
        $Script:ClientSecret -eq 'YOUR_CLIENT_SECRET') {
        Write-Error ('Please update $Script:ClientId and $Script:ClientSecret ' +
                     'in the script before running.')
        return
    }

    # Ensure output directory exists
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath | Out-Null
        Write-Host "Created output folder: $OutputPath"
    }

    # ------------------------------------------------------------------
    # Step 1 – Retrieve the list of all forms / apps
    # ------------------------------------------------------------------
    Write-Host "Fetching list of forms (apps) ..."
    $appsResponse = Invoke-GoCanvasRequest -Uri "$Script:V3BaseUrl/forms"
    $rawApps = Get-ObjectProperty -Object $appsResponse -Name 'forms'
    $apps = @(if ($rawApps) { $rawApps }
              elseif ($appsResponse -is [array]) { $appsResponse }
              else { @() })

    if ($apps.Count -eq 0) {
        Write-Warning "No forms/apps found. Verify your credentials and API access."
        return
    }

    Write-Host "Found $($apps.Count) form(s)." -ForegroundColor Green

    $totalDownloaded = 0
    $totalSkipped    = 0
    $totalFailed     = 0

    # ------------------------------------------------------------------
    # Step 2 – Process each form
    # ------------------------------------------------------------------
    foreach ($app in $apps) {
        $appId   = Get-ObjectProperty -Object $app -Name 'id'
        $rawName = Get-ObjectProperty -Object $app -Name 'name'
        $appName = if ($rawName) { $rawName } else { "App_$appId" }
        $safeApp = Get-SafeName -Name $appName

        Write-Host ""
        Write-Host "Form: $appName (ID: $appId)" -ForegroundColor Yellow

        # Create a sub-folder for this form
        $formFolder = Join-Path $OutputPath $safeApp
        if (-not (Test-Path $formFolder)) {
            New-Item -ItemType Directory -Path $formFolder | Out-Null
        }

        # Retrieve all submissions for this form
        $submissions = @(Get-AllSubmissions -AppId $appId)
        Write-Host "  Submissions found: $($submissions.Count)"

        # Build the per-form submissions index (CSV) as we go
        $indexRows = [System.Collections.Generic.List[object]]::new()

        foreach ($sub in $submissions) {
            $result = Save-Submission -Submission $sub -FormFolder $formFolder

            switch ($result.Status) {
                'Downloaded' { $totalDownloaded++ }
                'Skipped'    { $totalSkipped++ }
                'Failed'     { $totalFailed++ }
            }

            # Build the index row: every field returned by the API plus
            # computed columns describing the resulting filename(s).
            $row = ConvertTo-FlatSubmissionRecord -Submission $sub
            Add-Member -InputObject $row -NotePropertyName 'BaseFileName' `
                       -NotePropertyValue $result.BaseName -Force
            Add-Member -InputObject $row -NotePropertyName 'Files' `
                       -NotePropertyValue (($result.Files) -join ';') -Force
            Add-Member -InputObject $row -NotePropertyName 'DownloadStatus' `
                       -NotePropertyValue $result.Status -Force
            $indexRows.Add($row)
        }

        # Write the per-form CSV index of all submissions
        if ($indexRows.Count -gt 0) {
            $indexPath = Join-Path $formFolder '_submissions_index.csv'
            Write-SubmissionsIndex -Path $indexPath -Rows $indexRows.ToArray()
            Write-Host "  Wrote submissions index: $indexPath"
        }
    }

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "========== Summary ==========" -ForegroundColor Cyan
    Write-Host "Downloaded : $totalDownloaded"
    Write-Host "Skipped    : $totalSkipped"
    Write-Host "Failed     : $totalFailed"
    Write-Host "Output     : $OutputPath"
}

Invoke-Main
