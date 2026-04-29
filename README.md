# goCanvas-Downloader

A PowerShell script that connects to the [goCanvas API v3](https://api.gocanvas.com/api/v3/docs) and exports all available submission data. PDFs are downloaded where available; when a PDF is not available, **both** the CSV and XML versions are downloaded instead.

## Features

- Authenticates to the goCanvas API using **OAuth 2.0 Client Credentials** flow
- Retrieves every form (app) available in your goCanvas account
- Iterates through all submissions for each form, handling API pagination automatically
- Prefers **PDF** format; if PDF is unavailable, downloads **both** CSV and XML
- Names files using the submission's **reference id**, **name**, **user id** and **status**
- Writes a per-form **`_submissions_index.csv`** containing every field returned by the API for each submission, plus the resulting filename(s)
- Organises downloads into sub-folders named after each form
- Skips files that have already been downloaded (idempotent — safe to run repeatedly)

## Requirements

- Windows PowerShell 5.1 **or** PowerShell 7+
- Internet access to `https://api.gocanvas.com`
- A valid goCanvas account with API access
- An **OAuth application** created in your [goCanvas API settings](https://www.gocanvas.com/my_api_settings)

## Setup

1. Create an OAuth application in your [goCanvas profile](https://www.gocanvas.com/my_api_settings). Choose the **Client Credentials** flow (server-to-server). Note down the **Client ID** and **Client Secret** that are generated.

2. Open `Invoke-GoCanvasDownload.ps1` in a text editor.

3. Find the **CONFIGURATION** section near the top of the script and replace the placeholder values:

```powershell
$Script:ClientId     = 'YOUR_CLIENT_ID'
$Script:ClientSecret = 'YOUR_CLIENT_SECRET'
```

> **Security note:** The credentials are stored directly in the script as described in the requirements. Treat this file as sensitive and avoid committing it with real credentials to source control.

## Usage

```powershell
# Download to the default folder (.\GoCanvasDownloads) in the current directory
.\Invoke-GoCanvasDownload.ps1

# Specify a custom output path
.\Invoke-GoCanvasDownload.ps1 -OutputPath "C:\Exports\GoCanvas"

# Show verbose output (individual file operations)
.\Invoke-GoCanvasDownload.ps1 -Verbose
```

### Parameters

| Parameter    | Type   | Default                          | Description                              |
|-------------|--------|----------------------------------|------------------------------------------|
| `OutputPath` | String | `.\GoCanvasDownloads`           | Root folder where files are saved        |
| `PageSize`   | Int    | `100`                            | Submissions fetched per API request      |

## Output Structure

```
GoCanvasDownloads\
├── Form Name A\
│   ├── _submissions_index.csv
│   ├── REF001_Site_Inspection_42_complete.pdf
│   ├── REF002_Site_Inspection_42_complete.pdf
│   ├── REF003_Site_Inspection_17_draft.csv     ← PDF was unavailable, so both formats downloaded
│   └── REF003_Site_Inspection_17_draft.xml
└── Form Name B\
    ├── _submissions_index.csv
    ├── SUB_456_Vehicle_Check_8_complete.pdf
    ├── SUB_789_Vehicle_Check_8_complete.csv    ← PDF unavailable
    └── SUB_789_Vehicle_Check_8_complete.xml
```

File names follow the pattern `{reference_id}_{name}_{user_id}_{status}.{ext}`.
Any characters that are invalid in file names are replaced with underscores, and
overly long names are truncated.

### Submissions index CSV

Each form folder contains a `_submissions_index.csv` listing every submission
retrieved from the API for that form. The CSV includes **all** fields returned
by the API (nested objects are stored as compact JSON to preserve the data),
plus three computed columns:

| Column           | Description                                                              |
|------------------|--------------------------------------------------------------------------|
| `BaseFileName`   | The sanitised base filename (without extension) used on disk             |
| `Files`          | Semicolon-separated list of the file(s) saved (e.g. `REF.pdf` or `REF.csv;REF.xml`) |
| `DownloadStatus` | `Downloaded`, `Skipped` (already on disk), or `Failed`                  |

## How It Works

1. **Authentication** – On first use, the script exchanges your Client ID and Client Secret for a short-lived Bearer token via `POST /api/v3/oauth/token` (OAuth 2.0 Client Credentials flow). The token is cached in memory and automatically refreshed when it is within 60 seconds of expiry.
2. **List forms** – `GET /api/v3/apps` returns all forms/apps in your account.
3. **List submissions** – `GET /api/v3/submissions?app_id=…&page=…&per_page=…` is called repeatedly until all pages are retrieved.
4. **Download** – For each submission, the script attempts:
   - `GET /api/v3/submissions/{id}.pdf` — if successful, the submission is done.
   - If PDF is unavailable, it then downloads **both**:
     - `GET /api/v3/submissions/{id}.csv`
     - `GET /api/v3/submissions/{id}.xml`
5. **Skip existing** – A submission is treated as already downloaded (and skipped) when either the PDF exists, or both the CSV and XML exist on disk.
6. **Index** – After processing each form, a `_submissions_index.csv` is written into the form folder containing every submission record returned by the API together with its on-disk filename(s) and status.

## License

See [LICENSE](LICENSE).
