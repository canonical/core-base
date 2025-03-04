# Security policy

## Supported versions
<!-- Include start supported versions -->
The release model of the core22 snap is following rolling releases. 
The snap is released into the edge channel, and automatically promoted to 
the beta channel if a snap revision is not already in progress for beta validation. 
When reporting security issues against the core22 snap, only the latest 
release of the core22 snap is supported.

The core22 snap has regular releases that are fully automated. There are two 
types of security fixes that can be shipped with new versions of the core22 snap.

- Security fixes that are relevant to the files inside this repository.
- Security fixes that are carried from the official archives. I.e security fixes 
from debian packages carried inside the core22 snap.

<!-- Include end supported versions -->

## What qualifies as a security issue

Security vulnerability that apply to packages in the Jammy archives also shipped by the
core22 snap. Any vulnerability that allows the core22 snap to interfere outside 
of the intended restrictions also qualifies as a security issue.

## Reporting a vulnerability

The easiest way to report a security issue is through
[GitHub](https://github.com/canonical/core-base/security/advisories/new). See
[Privately reporting a security
vulnerability](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
for instructions.

Alternatively, please email [security@ubuntu.com](mailto:security@ubuntu.com) with a description of the issue, the
steps you took to create the issue, affected versions, and, if known, mitigations for the issue.

The Ubuntu Core GitHub admins will be notified of the issue and will work with you
to determine whether the issue qualifies as a security issue and, if so, in
which component. We will then handle figuring out a fix, getting a CVE
assigned and coordinating the release of the fix to the Snapd snap and the
various Ubuntu releases and Linux distributions.

The [Ubuntu Security disclosure and embargo
policy](https://ubuntu.com/security/disclosure-policy) contains more
information about what you can expect when you contact us, and what we
expect from you.
