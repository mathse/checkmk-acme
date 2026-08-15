# Checkmk ACME

Native **acme.sh** integration for the **Checkmk Appliance**.

This project automates certificate management for Checkmk Appliances by using the appliance's internal Webconf APIs instead of manually uploading certificates through the web interface.

It supports both **standalone appliances** and **Checkmk Appliance clusters**.

## Features

* Automatic Let's Encrypt (or any ACME CA supported by acme.sh)
* Uses the internal Checkmk Appliance Webconf API
* Works on standalone and clustered appliances
* Automatically skips certificate operations on standby cluster nodes
* Synchronizes certificates to the partner node using the appliance's built-in cluster synchronization
* No manual interaction with the Webconf GUI required

---

## Requirements

* Checkmk Appliance
* Root access
* `acme.sh`
* Python modules shipped with the appliance (`cma`, `webconf`)

---

## Installation Layout

This project is intentionally simple and is designed to live entirely in the **root user's home directory** on the appliance.

The examples in this README assume the following layout:

```text
/root/
├── .acme.sh/
│   └── deploy/
│       └── checkmk_appliance.sh
└── acme/
    ├── cma-acme.sh
    ├── cma-acme.conf
    └── deploy/
        └── checkmk_appliance.sh
```

The wrapper script expects the configuration file to be located at:

```text
/root/acme/cma-acme.conf
```

and installs the deploy hook into:

```text
/root/.acme.sh/deploy/checkmk_appliance.sh
```

If you prefer a different directory layout, simply adjust the paths in the wrapper script.

---

## Files

```
cma-acme.conf
```

Configuration file.

```
cma-acme.sh
```

Wrapper around `acme.sh`.

Provides the following commands:

* `issue`
* `renew`
* `status`

```
deploy/checkmk_appliance.sh
```

Custom acme.sh deploy hook.

The deploy hook installs the certificate using the appliance's internal Webconf functions and triggers the normal appliance activation and cluster synchronization.

---

## Installation

Clone this repository somewhere on the appliance, for example:

```bash
git clone https://github.com/<your-account>/checkmk-acme.git
cd checkmk-acme
```

Install **acme.sh** if it is not already installed.

The wrapper automatically installs the deploy hook into the acme.sh deployment directory if it is missing.

---

## Configuration

Edit `cma-acme.conf`.

Example:

```bash
# Basic Config
CERT_DOMAIN="monitor.example.com"
INCLUDE_NODE_NAMES=1
ACME_SERVER="letsencrypt"

ACME_HOME="/root/.acme.sh"

ACME_ISSUE_ARGS="--server $ACME_SERVER --dns dns_custom -d $CERT_DOMAIN"
```

Additional DNS provider credentials must be exported according to the requirements of your selected acme.sh DNS plugin.

Refer to the acme.sh documentation for supported providers.

---

## Usage

Issue a new certificate:

```bash
./cma-acme.sh issue
```

Renew an existing certificate:

```bash
./cma-acme.sh renew
```

Show current status:

```bash
./cma-acme.sh status
```

---

## Cluster behaviour

The wrapper automatically detects whether it is running on

* a standalone appliance
* the active cluster node
* the standby cluster node

On standby nodes the script exits successfully without performing any certificate operations.

The deploy hook performs the following steps on the active node:

1. Validate the private key and certificate.
2. Store the certificate using the appliance's internal Webconf functions.
3. Activate the new certificate using the normal `ssl_certs` hook.
4. Synchronize the updated certificate files to the partner node.

No manual Webconf interaction is required.

---

## Cron

The wrapper itself does **not** install any cron jobs.

A daily cron job should be created on **each cluster node**.

Running the wrapper on both nodes is safe because standby nodes automatically exit without doing any work.

Example:

```cron
0 3 * * * /root/acme/cma-acme.sh renew >/var/log/cma-acme.log 2>&1
```

---

## Status

The `status` command displays:

* Hostname
* Cluster state
* Current node role
* acme.sh installation status
* Deploy hook status
* Certificates currently managed by acme.sh

---

## Tested Environment

This project has currently been tested with the following environment:

| Component         | Version        |
| ----------------- | -------------- |
| Checkmk Appliance | **1.7.21**     |
| ACME challenge    | **dns_custom** |

At the moment, only the `dns_custom` acme.sh DNS provider has been tested. Other DNS providers should work as well, but have not yet been verified.

If you have successfully tested this project with other Checkmk Appliance versions or DNS providers, feel free to open a pull request or share your results.


---

## Disclaimer

This project uses internal Checkmk Appliance Python APIs (`cma` and `webconf`).

These APIs are not part of the public Checkmk interface and may change between appliance releases.

Always verify the functionality after upgrading your Checkmk Appliance.

---

## License

MIT
