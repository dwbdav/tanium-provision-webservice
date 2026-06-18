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

This repository contains the code, reusable scripts, and example runtime folders.

It does not include:

- production CSV data
- runtime logs
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

The repository already includes the expected runtime folders:

- `data_csv/` for configuration data, with example CSV headers
- `logs/` for logs and deployment tracking
- `.secret_key` for the Flask secret key

The `data_csv/` content is provided as a starter example. Replace it with your own deployment data before production use.
Only the `logs/README.md` file is tracked; runtime log files are ignored by Git.

## CSV Templates

Template headers are available directly in `data_csv/`.
The goal is to copy or clone this repository and keep the expected folder structure ready to use.

## Security Notes

- Keep this repository private unless you have reviewed the code and removed environment-specific values.
- Do not commit real production CSV data, logs, serial numbers, passwords or package binaries.
- Change the default admin password after first login.
- If the file API is exposed, use the `WS_FILE_TOKEN` option.

## Tanium Scripts

The scripts in `file/Provision/` are intended to be used as Tanium Provision customer scripts.
Update the Web Service URL or generated context before adding them to a production bundle.
