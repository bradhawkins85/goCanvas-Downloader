# goCanvas-Downloader

A PowerShell script that connects to the [goCanvas API v3](https://api.gocanvas.com/api/v3/docs) and exports all available submission data. PDFs are downloaded where available; CSV and XML are used as fallbacks.

## Features

- Authenticates to the goCanvas API using Basic Authentication (email + password / API key)
- Retrieves every form (app) available in your goCanvas account
- Iterates through all submissions for each form, handling API pagination automatically
- Prefers **PDF** format; falls back to **CSV**, then **XML** if PDF is unavailable
- Organises downloads into sub-folders named after each form
- Skips files that have already been downloaded (idempotent — safe to run repeatedly)

## Requirements

- Windows PowerShell 5.1 **or** PowerShell 7+
- Internet access to `https://api.gocanvas.com`
- A valid goCanvas account with API access

## Setup

1. Open `Invoke-GoCanvasDownload.ps1` in a text editor.
2. Find the **CONFIGURATION** section near the top of the script and replace the placeholder values:

```powershell
$Script:ApiUsername = 'YOUR_GOCANVAS_EMAIL'
$Script:ApiPassword = 'YOUR_GOCANVAS_PASSWORD_OR_API_KEY'
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
│   ├── REF001.pdf
│   ├── REF002.pdf
│   └── REF003.csv          ← PDF was unavailable for this submission
└── Form Name B\
    ├── SUB_456.pdf
    └── SUB_789.xml         ← Neither PDF nor CSV was available
```

File names are derived from the submission's `reference_id`. Any characters that are
invalid in file names are replaced with underscores.

## How It Works

1. **Authentication** – Every API request includes an `Authorization: Basic …` header built from your credentials.
2. **List forms** – `GET /api/v3/apps` returns all forms/apps in your account.
3. **List submissions** – `GET /api/v3/submissions?app_id=…&page=…&per_page=…` is called repeatedly until all pages are retrieved.
4. **Download** – For each submission, the script attempts:
   - `GET /api/v3/submissions/{id}.pdf`
   - `GET /api/v3/submissions/{id}.csv` (if PDF returns 404)
   - `GET /api/v3/submissions/{id}.xml` (if CSV also returns 404)
5. **Skip existing** – If a file already exists on disk, the submission is counted as skipped and not re-downloaded.

## License

See [LICENSE](LICENSE).
