# Tanium Provision MDT-Like Web Service

Python Web Service used with Tanium Provision to add MDT-like logic during Windows deployment.

## Main Features

- Computer lookup by serial number
- Computer name, type, country, language, timezone and keyboard values
- Application selection by deployment type
- Optional country and model filters for applications
- Optional reboot handling after application install
- Driver package selection by model and OS regex
- Tanium Provision Web Service variables for Bundle ID selection
- Deployment messages and progress tracking
- CSV-backed configuration for portability

## Repository Content

This repository contains only the code and reusable scripts.

It does not include:

- production CSV data
- logs
- secret keys
- WIM, ISO, MSI, EXE or ZIP payloads
- lab bundle content

## Quick Start

1. Copy the repository to the target server, for example `C:\WebService`.
2. Install Python.
3. Run `install\install.ps1` to create the virtual environment and install dependencies.
4. Start the service with `install\StartWebService.ps1`.
5. Open the Web Service on port `12176`, or publish it behind IIS with a reverse proxy.

## Runtime Data

The application creates and uses local runtime folders:

- `data_csv/` for configuration data
- `logs/` for logs and deployment tracking
- `.secret_key` for the Flask secret key

These files are intentionally ignored by Git.

## CSV Templates

Template headers are available in `data_csv.example/`.
Copy them to `data_csv/` before first use if you want to pre-create the files.

## Security Notes

- Keep this repository private unless you have reviewed the code and removed environment-specific values.
- Do not commit real `data_csv/`, logs, serial numbers, passwords or package binaries.
- Change the default admin password after first login.
- If the file API is exposed, use the `WS_FILE_TOKEN` option.

## Tanium Scripts

The scripts in `file/Provision/` are intended to be used as Tanium Provision customer scripts.
Update the Web Service URL or generated context before adding them to a production bundle.
