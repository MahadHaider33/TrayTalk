# Install and setup

- Build in XCode.
- Copy Smooth Talker.app to ~/Applications

# Permissions

Requires OSX Accessibility permission.

Note: You may have to restart it after giving it permission.

# Automatic Google Cloud setup runtime

Automatic setup uses a private Smooth Talker runtime under `~/Library/Application Support/Smooth Talker/`. It must not use Homebrew, system Python, user shell files, or the user's normal Google Cloud CLI configuration.

Release builds should include these pinned runtime archives in `TrayTalk/GoogleCloudRuntime/`:

- `google-cloud-cli-darwin-arm.tar.gz`
- `cpython-3.10.20+20260510-aarch64-apple-darwin-install_only.tar.gz`

After adding or updating archives, update `TrayTalk/GoogleCloudRuntime/runtime-manifest.json` with the SHA256 for each archive. Smooth Talker verifies these checksums before expanding the runtime into Application Support.

# Google Cloud Service account (json)

```
{
  "type": "service_account",
  "project_id": "XXX",
  "private_key_id": "XXX",
  "private_key": "XXX",
  "client_email": "XXX",
  "client_id": "XXX",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token",
  "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
  "client_x509_cert_url": "XXX",
  "universe_domain": "googleapis.com"
}
```
