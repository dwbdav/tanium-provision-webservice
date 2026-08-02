# data_csv

This folder contains CSV templates used by the Web Service.

The tracked `*.example.csv` files contain only the expected headers. Copy each
required template to the same name without `.example` before starting the
service, for example `users.example.csv` to `users.csv`.

Runtime `*.csv` files are ignored by Git so production inventory and credentials
cannot be staged accidentally.

Do not force-add production inventory, serial numbers, credentials, package IDs,
or internal-only values.
