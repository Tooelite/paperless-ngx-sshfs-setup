# Paperless NGX SSHFS Setup (Proxmox LXC)

This repository provides a Bash script to move **Paperless NGX** data directories onto a remote SSH host using **SSHFS**, intended for use inside a **Proxmox LXC container**.  
The goal is to store growing document data outside of the container while keeping Paperless itself untouched and operational.

---

## Features

- Interactive configuration prompt (SSH user, host, path, key creation, etc.)
- Creates a dedicated SSH key (optional automatic deployment using `ssh-copy-id`)
- Writes a persistent SSHFS mount through `/etc/fstab`
- Automatically creates all Paperless NGX data subfolders:
  - `consume/`
  - `data/`
  - `media/`
  - `trash/`
- No modification of Paperless NGX itself required

---

## Requirements

### Proxmox

- LXC container (Debian/Ubuntu recommended)
- **FUSE enabled** in container options

  Proxmox UI → Container → Options → Features → enable `fuse`

### Inside the container

- root access
- working SSH connectivity to remote host
- required packages:
  - `ssh`
  - `sshfs`

The script will install `sshfs` if missing.

### Remote system (SSH host)

- SSH enabled
- Accessible data path (e.g. `/srv/paperless_data`)

---

## Installation

```bash
apt update
apt install -y curl
curl -o paperless-sshfs-setup.sh   https://raw.githubusercontent.com/<USER>/<REPO>/main/paperless-sshfs-setup.sh

chmod +x paperless-sshfs-setup.sh
```

---

## Usage

```bash
./paperless-sshfs-setup.sh
```

The script will guide you through:

1. SSH credentials and remote path
2. SSH key creation
3. Optional public key transfer via `ssh-copy-id`
4. Adding an SSHFS entry to `/etc/fstab`
5. Mounting
6. Creating Paperless subdirectories

---

## Result

After successful setup you will have a mount like:

```
/mnt/paperless_data/
    consume/
    data/
    media/
    trash/
```

### Paperless NGX configuration values

Insert these lines into your `.env` or `docker-compose.yml`:

```env
PAPERLESS_CONSUMPTION_DIR=/mnt/paperless_data/consume
PAPERLESS_DATA_DIR=/mnt/paperless_data/data
PAPERLESS_MEDIA_ROOT=/mnt/paperless_data/media
PAPERLESS_EMPTY_TRASH_DIR=/mnt/paperless_data/trash
```

---

## Example `/etc/fstab` entry

```
sshfs#paperless@192.168.1.10:/srv/paperless_data /mnt/paperless_data fuse defaults,_netdev,allow_other,IdentityFile=/root/.ssh/id_rsa_paperless_share 0 0
```

Test mounting:

```bash
mount -a
mountpoint -q /mnt/paperless_data && echo "SSHFS OK"
```

---

## Security

- `allow_other` exposes mounted files to all users inside the container — adjust if necessary.
- Secure key management is recommended.
- Restrict SSH access via firewall or internal-only network segments.
- Remote data path should ideally be dedicated to Paperless.

---

## Troubleshooting

### "mount: unknown filesystem type 'fuse'"

→ Enable FUSE in Proxmox container configuration and restart the container.

### "Permission denied" when accessing the mount

- Ensure the public key is in `~/.ssh/authorized_keys` on the remote host.
- Correct permissions:
  ```
  chmod 700 ~/.ssh
  chmod 600 ~/.ssh/authorized_keys
  ```

### SSHFS mount fails at boot

- Ensure `_netdev` is present in `/etc/fstab`
- Optionally add `x-systemd.automount` for stable mounting

---

## License

MIT

---

## Notes

This repository contains **only the SSHFS setup script**.  
Paperless NGX installation and configuration must be handled separately.

---

## Contributing

Issues and PRs are welcome.
