# IIS Setup (LVL 1)

Setting up a simple web application using IIS (Internet Information Services) on Windows 10 Enterprise, including SSL certificate configuration and domain binding.

## Installation & Configuration

1. Install IIS
- Control Panel → Programs → Turn Windows features on/off
- Enable Internet Information Services + Management Console
- Verify: `http://localhost`

2. Create Website
- Folder: `C:\inetpub\wwwroot` with index.html
- IIS → Add Website → Name: MyWebApp
- Port: 8080 (not 80 - see Issue #1)

3. Domain Binding
- Add to C:\Windows\System32\drivers\etc\hosts:
`127.0.0.1   <domain-name>`
- IIS → Bindings → Add:
- Type: `http / Port: 80 / Host: <domain-name>`

4. SSL Certificate
PowerShell (Admin):
```powershell
New-SelfSignedCertificate -DnsName "<domain-name>" -CertStoreLocation "cert:\LocalMachine\My" -FriendlyName "Bootcamp Task 3" -KeyUsage DigitalSignature,KeyEncipherment -KeyLength 2048 -NotAfter (Get-Date).AddYears(3)
```
- IIS: Add HTTPS binding → Port: 443 → Select certificate

5. HTTP → HTTPS Redirect (URL Rewrite)
Name: `Redirect to HTTPS`
Match: `(.*)`
Condition: `{HTTPS} = ^OFF$`
Action: Redirect to `https://{SERVER_NAME}/{R:1}` (301)

6. Result check
![Accessing a website using its domain name and https protocol](screenshot.png)

## Issues & Fixes
| # | Problrm | Fix |
| - | ------- | --- |
| 1 | Site not accessible on port 80	| Used port 8080 (Intel service was using 80) |
| 2	| Domain not resolving | Added entry to hosts file |
| 3 | ERR_SSL_PROTOCOL_ERROR | Forgot HTTPS binding - added it |
| 4 |	Redirect didn't work for localhost:8080 |	Changed {HTTP_HOST} → {SERVER_NAME} in rule |
| 5 |	ERR_SSL_KEY_USAGE_INCOMPATIBLE	| Created cert via PowerShell (not IIS GUI) |