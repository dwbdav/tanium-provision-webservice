# Installation files

Install the prerequisites manually in this order:

1. Enable the Windows Server IIS role and management tools.
2. Run `rewrite_amd64_en-US.msi`.
3. Run `requestRouter_amd64.msi`.
4. Run `python-3.13.13-amd64.exe`, select an all-users installation, and use
   `C:\Program Files\Python313` as the target directory.
5. Run `install.ps1` from an elevated PowerShell session.

`install.ps1` creates the virtual environment and installs Python packages. It
does not install Python, IIS, URL Rewrite, or ARR.

## Verified installers

| File | Publisher | SHA-256 |
| --- | --- | --- |
| `rewrite_amd64_en-US.msi` | Microsoft Corporation | `37342FF2F585F263F34F48E9DE59EB1051D61015A8E967DBDE4075716230A32A` |
| `requestRouter_amd64.msi` | Microsoft Corporation | `FB61FDB7101795A34D5129CB37EEE43AB675C7ED76BA3A3B23B039D8C90C2A4B` |
| `python-3.13.13-amd64.exe` | Python Software Foundation | `3C9C81D80F91C002CED86D645422D81432C68C7D9B6B0E974768CA2E449A4D00` |

Official sources:

- <https://www.iis.net/downloads/microsoft/url-rewrite>
- <https://www.iis.net/downloads/microsoft/application-request-routing>
