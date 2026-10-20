# oci-grab

Oracle Cloud's Always Free servers are often "out of capacity", and the only fix
is to keep asking until one frees up. This repo does the asking for me: every 10
minutes a GitHub Actions workflow runs `oci-grab.sh`, and once the server exists
it opens an issue and switches itself off.

**Status:** it got the server on 19 Oct 2026, so the workflow is switched off now.

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

## What starts it every 10 minutes
GitHub's own `schedule` timer never fired for this repo, so
[cron-job.org](https://cron-job.org) (free) starts the workflow instead, the same
way the **Run workflow** button does:

| Setting | Value |
|---|---|
| URL | `https://api.github.com/repos/maniesh-lab/oci-grab/actions/workflows/grab.yml/dispatches` |
| Schedule | every 10 minutes |
| Method | `POST` |
| Headers | `Authorization: Bearer <token>`, `Accept: application/vnd.github+json`, `Content-Type: application/json` |
| Body | `{"ref":"main"}` |

The token is a fine-grained GitHub token limited to this one repo, with only
**Actions: read and write**, so it can start workflows and nothing else. A good
call returns `204`. The `schedule` in `grab.yml` stays as a backup in case
GitHub's timer starts working.

## When it gets one
It opens an issue titled **"Oracle server is ready"** that @mentions me (so GitHub
emails me) and disables the workflow. After that, delete the cron-job.org job,
since it would only keep hitting a disabled workflow.
The public IP is in the Oracle console (Compute → Instances → hearth). The log
doesn't print it, or any Oracle IDs, because this repo is public.

## Running it on a laptop instead
```bash
bash oci-grab.sh           # keeps trying every ~2 minutes until it gets one
ONCE=1 bash oci-grab.sh    # one try per shape, then exits
```

## Known Limitations
- It only tries the first availability domain in your region. In a region with
  more than one, the others are never asked
- It looks for the network and creates the server in the root compartment
  (the tenancy), not in a sub-compartment
- The server name (`hearth`) and network name (`hearth-vcn`) are set at the top
  of `oci-grab.sh`, so change them there for a different setup

## Author

**Manish Pandeya** · [github.com/maniesh-lab](https://github.com/maniesh-lab)
