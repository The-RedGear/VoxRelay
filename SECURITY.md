# Security policy

Please do not publicly disclose vulnerabilities that could expose credentials,
execute unintended commands, or access private files.

Report security issues privately through GitHub's **Report a vulnerability**
feature when it is available for this repository. Include reproduction steps,
the affected version, and the expected impact. Do not include real credentials
or private user data in the report.

VoxRelay credentials must never be committed to the repository. Amazon Polly
keys saved by the desktop application are protected with Windows DPAPI for the
current user account.
