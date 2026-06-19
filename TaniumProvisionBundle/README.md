# TaniumProvisionBundle

This folder contains example content used to build a Tanium Provision OS bundle.

Before importing or using this content, update the Web Service URL in:

```text
OtherFile/Customer-PE-Pre.ps1
```

Default example value:

```text
https://provision.example.local/
```

Replace it with the URL of your own provisioning Web Service.

The `Drivers/` and `Wim/` folders are intentionally kept as bundle placeholders. Add your own driver content and Windows image files locally when building the final Tanium bundle.
