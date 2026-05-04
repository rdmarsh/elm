# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.6.0   | :white_check_mark: |
| 1.5.0   | :white_check_mark: |
| 1.4.0   | :x:                |
| 1.3.0   | :x:                |
| 1.2.4   | :x:                |
| 1.2.3   | :x:                |
| 1.2.2   | :x:                |
| 1.2.1   | :x:                |
| 1.2.0   | :x:                |
| 1.1.0   | :x:                |
| 1.0.6   | :x:                |
| 1.0.5   | :x:                |
| 1.0.4   | :x:                |
| 1.0.3   | :x:                |
| 1.0.2   | :x:                |
| 1.0.1   | :x:                |
| < 1.0   | :x:                |

## Security History

Known dependency vulnerabilities fixed, by version. Versions prior to 1.2.1
were not tracked.

### 1.6.0

- **lxml 5.2.1 → 6.1** — XXE (XML External Entity) injection vulnerability
  (HIGH). Affected any code parsing untrusted XML; here the API responses
  are from LogicMonitor directly, but upgrading removes the exposure.
- **Pygments 2.15.0 → 2.20** — ReDoS (Regular Expression Denial of Service)
  vulnerability (LOW). Could cause slow response when formatting output
  containing certain patterns.
- **requests 2.32.0 → 2.33** — Insecure temporary file reuse (MEDIUM).

### 1.2.1

- **requests 2.31.0 → 2.32.0** —
  [CVE-2024-35195](https://nvd.nist.gov/vuln/detail/CVE-2024-35195): proxy
  credentials leaked via HTTP redirect when using a SOCKS5 proxy (MEDIUM).
  elm's `--proxy` flag uses SOCKS5, so this was directly applicable.

## Reporting a Vulnerability

For sensitive bugs like security vulnerabilities, please contact
rdmarsh@gmail.com directly or use [githubs vulnerability reporting
function] instead of the issue tracker. We appreciate your effort to
improve the security and privacy of this project!

## Responsible Disclosure Guidelines

Please follow these guidelines when reporting security vulnerabilities:

1. **Keep it Confidential:** Do not disclose the vulnerability publicly
   until it has been addressed.

2. **Provide Clear Details:** When reporting a vulnerability, include as
   much detail as possible, such as:
   * Description of the vulnerability
   * Steps to reproduce the issue
   * Impact assessment (what data could be affected, etc.)

3. **Be Respectful:** Understand that security vulnerabilities can have
   significant implications. Please be courteous in your communications.

4. **Use the Correct Channels:** Report vulnerabilities through the
   specified contact methods (email or GitHub’s reporting function) to
   ensure they are received promptly.

5. **No Exploitation:** Do not exploit the vulnerability or attempt to gain
   unauthorised access to systems, accounts, or data.

6. **Give Us Time:** Allow us a reasonable time frame to investigate and
   address the issue before making any public disclosures.

7. **Stay Engaged:** Feel free to follow up if you don’t receive an
   acknowledgement within a few days.

By following these guidelines, you help us maintain the security and
integrity of our project. Thank you for your cooperation!

[githubs vulnerability reporting function]: https://github.com/rdmarsh/elm/security
