# oci-grab

Oracle Cloud's Always Free servers are often "out of capacity", and the only fix
is to keep asking until one frees up. This repo does the asking for me: a GitHub
Actions workflow runs `oci-grab.sh` every 10 minutes, and switches itself off
once the server exists.

## What it asks for
- **Ampere A1** (1 OCPU, 6 GB, ARM) with Ubuntu 24.04, or
- **AMD E2.1.Micro** (1 GB, x86) with Ubuntu 24.04

Both are Always Free. It uses the `hearth-vcn` network's public subnet, gives
the server a public IP, and names it `hearth`. Before every try it checks that a
`hearth` server doesn't already exist, so it never makes two.

## Secrets it needs
Settings → Secrets and variables → Actions:

| Secret | What goes in it |
|---|---|
| `OCI_CONFIG` | the contents of `~/.oci/config` |
| `OCI_KEY` | the contents of the private API key (`~/.oci/oci_api_key.pem`) |
| `SSH_PUBLIC_KEY` | the contents of `~/.ssh/id_ed25519.pub` |

## When it gets one
It opens an issue titled **"Oracle server is ready"** and disables the workflow.
The public IP is in the Oracle console (Compute → Instances → hearth). The log
doesn't print it, or any Oracle IDs, because this repo is public.

## Running it on a laptop instead
```bash
bash oci-grab.sh           # keeps trying every ~2 minutes until it gets one
ONCE=1 bash oci-grab.sh    # one try per shape, then exits
```
