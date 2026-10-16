# Gabbaya

A patched Docker distribution of [InvoicePlane](https://github.com/InvoicePlane/InvoicePlane) v1,
the self-hosted open source invoicing application.

Gabbaya builds the **official InvoicePlane release** and applies a small, documented set of
patches on top of it (see [`patches/series`](patches/series)). Patches are meant to go
upstream; once InvoicePlane ships a change, the patch is dropped here.

> Gabbaya is not affiliated with InvoicePlane. "InvoicePlane" and its logo are trademarks of
> InvoicePlane.com / Kovah.de and are used here only to describe what this image contains.

**Image:** `ghcr.io/torreirow/gabbaya`

## How it works

| File                          | Purpose                                                        |
| ----------------------------- | -------------------------------------------------------------- |
| `UPSTREAM_VERSION`            | InvoicePlane release the image is built from                   |
| `UPSTREAM_SHA256`             | Checksum of that release zip, verified during the build        |
| `patches/series`              | Ordered patch list; every patch has a status (`upstream:<PR>` or `downstream-only:<reason>`) |
| `scripts/apply-patches.sh`    | Applies the series; the build fails if a patch no longer applies |

- **Build** (`.github/workflows/build.yml`): builds the pinned release with the patch series,
  smoke-tests it against MariaDB and pushes to ghcr.io from `main`.
- **Upstream check** (`.github/workflows/check-upstream.yml`): weekly; opens a PR bumping
  `UPSTREAM_VERSION`/`UPSTREAM_SHA256` when InvoicePlane publishes a new stable release.
  A patch that upstream has merged makes the build fail, which is the signal to drop it.

## Quick Start

```bash
docker compose up -d
```

Access at `http://localhost:8080` and follow the setup wizard.

**Note:** After completing the setup wizard, the container automatically sets
`DISABLE_SETUP=true` on the next restart. To re-enable the wizard (e.g. for a database
upgrade), set `DISABLE_SETUP=false`.

## Environment Variables

### Docker/PHP Settings

- `TZ` - Timezone (default: UTC)
- `PHP_MEMORY_LIMIT` - PHP memory limit (default: 256M)
- `PHP_UPLOAD_MAX_FILESIZE` - Maximum upload file size (default: 32M)
- `PHP_POST_MAX_SIZE` - Maximum POST size (default: 32M)
- `PHP_MAX_EXECUTION_TIME` - Maximum execution time in seconds (default: 300)

### Proxy Settings

- `PROXY_NETWORKS` - Space-separated list of trusted proxy IP ranges for X-Forwarded-For headers (default: "172.16.0.0/12 10.0.0.0/8")

### InvoicePlane Configuration

**Application Settings:**
- `IP_URL` - Base URL for InvoicePlane (e.g. https://invoice.example.com) - **Required for correct redirects**
- `ENABLE_DEBUG` - Enable debug logging (default: false)
- `CI_ENV` - Environment mode: production or development (default: production)
- `DISABLE_SETUP` - Disable setup wizard for security (default: false)
- `REMOVE_INDEXPHP` - Remove index.php from URLs (default: false)

**Database Settings:**
Note: These are only set if empty. Setup wizard values take precedence.
- `IP_DB_HOSTNAME` - Database hostname
- `IP_DB_USERNAME` - Database username
- `IP_DB_PASSWORD` - Database password
- `IP_DB_DATABASE` - Database name
- `IP_DB_PORT` - Database port (default: 3306)
- `IP_DB_PREFIX` - Table prefix (default: ip_)

**Security Settings:**
- `X_FRAME_OPTIONS` - X-Frame-Options header (default: SAMEORIGIN)
- `ENABLE_X_CONTENT_TYPE_OPTIONS` - Enable X-Content-Type-Options header (default: true)
- `SESS_REGENERATE_DESTROY` - Destroy session on regeneration (default: false)

**Session Settings:**
- `SESS_EXPIRATION` - Session expiration in seconds, 0 for browser close (default: 864000 = 10 days)
- `SESS_MATCH_IP` - Match session to IP address (default: true)

**Calculation Settings:**
- `LEGACY_CALCULATION` - Use legacy tax calculation (default: true)

**Feature Flags:**
- `ENABLE_INVOICE_DELETION` - Allow invoice deletion (default: false)
- `DISABLE_READ_ONLY` - Disable read-only mode for invoices (default: false)

**Swiss Medical (Sumex):**
- `SUMEX_SETTINGS` - Enable Sumex customizations (default: false)
- `SUMEX_URL` - Sumex PDF generation URL

**E-Invoice Templates:**
- `INSTALL_EINVOICE_TEMPLATES` - Comma-separated list of e-invoice templates to install on startup (e.g., "zugferd-extended,facturx")

## Volumes

- `/var/www/html/uploads` - Uploaded files
- `/var/www/html/application/logs` - Application logs
- `/config` - `ipconfig.php` (encryption key, setup state). **Mount this**, otherwise a
  re-created container (e.g. on an image upgrade) starts with a fresh `ipconfig.php`.
  An existing in-container `ipconfig.php` is moved here on first start. Override the
  location with `GABBAYA_CONFIG_DIR`.

## E-Invoice Support

InvoicePlane supports various e-invoice formats (ZUGFeRD, Factur-X, UBL, FacturaE, FatturaPA). Templates can be installed automatically via environment variable or manually using the included script.

### Automatic Installation (via Environment Variable)

Set the `INSTALL_EINVOICE_TEMPLATES` environment variable with a comma-separated list of template IDs:

```yaml
environment:
  - INSTALL_EINVOICE_TEMPLATES=zugferd-extended,facturx
```

**Available template IDs:**
- `facturxv10`, `facturx` - Factur-X v1.0 (French)
- `ublexamv20`, `ubl` - UBL 2.0 Example (Universal)
- `zugferdv23extended`, `zugferd-extended` - ZUGFeRD v2.3 Extended (German)
- `zugferdv23basic`, `zugferd-basic` - ZUGFeRD v2.3 Basic (German)
- `zugferdv23basicwl`, `zugferd-basicwl` - ZUGFeRD v2.3 Basic WL (German)
- `facturaev32`, `facturae` - FacturaE v3.2 (Spanish)
- `fatturapav12`, `fatturapa` - FatturaPA v1.2 (Italian)

### Manual Installation (Interactive Script)

You can also install templates manually using the interactive script:

```bash
docker exec -it gabbaya download-einvoice-templates.sh
```

For more information: [InvoicePlane E-Invoices Repository](https://github.com/InvoicePlane/InvoicePlane-e-invoices)

## Image Tags

| Tag                     | Description                                   |
| ----------------------- | --------------------------------------------- |
| `latest`                | Newest build from `main`                      |
| `<version>`             | e.g. `1.7.2`: newest build of that release    |
| `<version>-<commit>`    | e.g. `1.7.2-ab12cd3`: one specific build      |

Pin by digest in production.

## Credits and License

Gabbaya started as a fork of
[funktionslust/invoiceplane-docker](https://github.com/funktionslust/invoiceplane-docker)
by Funktionslust GmbH - Wolfgang Stark. Thank you!

The Docker configuration (Dockerfile, scripts, workflows) is licensed under the MIT License,
see [LICENSE](LICENSE). InvoicePlane itself is licensed under its own MIT-style license, see
[InvoicePlane LICENSE](https://github.com/InvoicePlane/InvoicePlane/blob/develop/LICENSE.txt).
