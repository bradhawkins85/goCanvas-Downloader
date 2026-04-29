<#
.SYNOPSIS
    Downloads all available goCanvas submission documents to a local directory.

.DESCRIPTION
    Connects to the goCanvas API v3, retrieves all available submissions across
    all forms/apps, and downloads each submission as a PDF. If a PDF is not
    available for a submission, BOTH the CSV and XML versions are downloaded
    instead. Already-downloaded files are skipped.

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
# !! CONFIGURATION — replace these values with your goCanvas credentials !!
# ---------------------------------------------------------------------------
$Script:ApiUsername = 'YOUR_GOCANVAS_EMAIL'
$Script:ApiPassword = 'YOUR_GOCANVAS_PASSWORD_OR_API_KEY'
# ---------------------------------------------------------------------------

$Script:V3BaseUrl = 'https://api.gocanvas.com/api/v3'

# ---------------------------------------------------------------------------
# Helper: build an Authorization header value
# ---------------------------------------------------------------------------
function Get-BasicAuthHeader {
    $pair  = '{0}:{1}' -f $Script:ApiUsername, $Script:ApiPassword
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
    'Basic ' + [Convert]::ToBase64String($bytes)
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
        Authorization = Get-BasicAuthHeader
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
        Authorization = Get-BasicAuthHeader
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
    ($Name -replace $re, '_').Trim()
}

# ---------------------------------------------------------------------------
# Retrieve every page of submissions for a given form (app_id)
# Returns an array of submission objects
# ---------------------------------------------------------------------------
function Get-AllSubmissions {
    param ([string]$AppId)

    $allSubmissions = [System.Collections.Generic.List[object]]::new()
    $page           = 1

    do {
        $query = @{
            app_id   = $AppId
            page     = [string]$page
            per_page = [string]$PageSize
        }

        $result = Invoke-GoCanvasRequest -Uri "$Script:V3BaseUrl/submissions" -Query $query

        $submissions = if ($result.submissions) { $result.submissions }
                       elseif ($result -is [array]) { $result }
                       else { @() }

        foreach ($sub in $submissions) {
            $allSubmissions.Add($sub)
        }

        # Determine whether there are more pages
        $total      = if ($result.total_count) { [int]$result.total_count } else { $allSubmissions.Count }
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
# Returns a comma-separated list of formats successfully saved,
# or $null if nothing could be downloaded.
# ---------------------------------------------------------------------------
function Save-Submission {
    param (
        [object]$Submission,
        [string]$FormFolder
    )

    $submissionId = [string]$Submission.id
    $refId        = if ($Submission.reference_id) { $Submission.reference_id } else { $submissionId }
    $safeName     = Get-SafeName -Name ([string]$refId)

    # ---- 1. Try PDF first ------------------------------------------------
    $pdfOk = Save-SubmissionFormat -SubmissionId $submissionId `
                                   -FormFolder   $FormFolder `
                                   -SafeName     $safeName `
                                   -Extension    'pdf'

    if ($pdfOk) {
        return 'pdf'
    }

    # ---- 2. PDF failed -> download BOTH CSV and XML ----------------------
    $saved = @()

    $csvOk = Save-SubmissionFormat -SubmissionId $submissionId `
                                   -FormFolder   $FormFolder `
                                   -SafeName     $safeName `
                                   -Extension    'csv'
    if ($csvOk) { $saved += 'csv' }

    $xmlOk = Save-SubmissionFormat -SubmissionId $submissionId `
                                   -FormFolder   $FormFolder `
                                   -SafeName     $safeName `
                                   -Extension    'xml'
    if ($xmlOk) { $saved += 'xml' }

    if ($saved.Count -gt 0) {
        return ($saved -join ',')
    }

    Write-Warning "  [FAIL] Could not download submission $submissionId in any format."
    return $null
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
    if ($Script:ApiUsername -eq 'YOUR_GOCANVAS_EMAIL' -or
        $Script:ApiPassword -eq 'YOUR_GOCANVAS_PASSWORD_OR_API_KEY') {
        Write-Error ('Please update $Script:ApiUsername and $Script:ApiPassword ' +
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
    $appsResponse = Invoke-GoCanvasRequest -Uri "$Script:V3BaseUrl/apps"
    $apps = if ($appsResponse.apps) { $appsResponse.apps }
            elseif ($appsResponse -is [array]) { $appsResponse }
            else { @() }

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
        $appId   = $app.id
        $appName = if ($app.name) { $app.name } else { "App_$appId" }
        $safeApp = Get-SafeName -Name $appName

        Write-Host ""
        Write-Host "Form: $appName (ID: $appId)" -ForegroundColor Yellow

        # Create a sub-folder for this form
        $formFolder = Join-Path $OutputPath $safeApp
        if (-not (Test-Path $formFolder)) {
            New-Item -ItemType Directory -Path $formFolder | Out-Null
        }

        # Retrieve all submissions for this form
        $submissions = Get-AllSubmissions -AppId $appId
        Write-Host "  Submissions found: $($submissions.Count)"

        foreach ($sub in $submissions) {
            $submissionId = $sub.id
            $refId        = if ($sub.reference_id) { $sub.reference_id } else { $submissionId }
            $safeName     = Get-SafeName -Name ([string]$refId)

            # A submission is considered "already on disk" when EITHER:
            #   - the PDF is present, OR
            #   - both the CSV and XML are present (the PDF-unavailable fallback)
            $pdfPath = Join-Path $formFolder ('{0}.pdf' -f $safeName)
            $csvPath = Join-Path $formFolder ('{0}.csv' -f $safeName)
            $xmlPath = Join-Path $formFolder ('{0}.xml' -f $safeName)

            $alreadyExists = (Test-Path $pdfPath) -or
                             ((Test-Path $csvPath) -and (Test-Path $xmlPath))

            if ($alreadyExists) {
                Write-Verbose "  [SKIP] Submission $submissionId ($refId) already on disk."
                $totalSkipped++
                continue
            }

            $result = Save-Submission -Submission $sub -FormFolder $formFolder
            if ($result) {
                $totalDownloaded++
            }
            else {
                $totalFailed++
            }
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
