# craft-sync

A CLI tool for syncing Craft CMS assets and databases between environments via SSH. Dynamically resolves volume paths and storage directories from the Craft installation itself, with support for multiple environments, dry runs, and per-volume syncing.

## Requirements

- Bash
- SSH access to the remote server
- Craft CMS 5.x
- `rsync` installed on both local and remote machines

## Installation

Download the script into your project's `scripts/` folder:

```bash
cd my-craft-project
mkdir -p scripts
curl -o scripts/sync.sh https://raw.githubusercontent.com/lewisjenkins/craft-sync/main/sync.sh
chmod +x scripts/sync.sh
```

The script must be located in a folder one level below the Craft project root (the directory containing the `craft` binary and `.env` file). The `scripts/` folder name is a convention — the folder can be named anything, but its location relative to the project root must be maintained:

```
my-craft-project/
├── .env
├── craft
├── scripts/
│   └── sync.sh
└── ...
```

## Configuration

Add your environment connection details to your project's `.env` file:

```dotenv
SYNC_PRODUCTION=user@example.com:/home/user/my-craft-project
SYNC_STAGING=user@staging.example.com:/home/user/my-craft-project
```

The format is `SYNC_<ENVIRONMENT>=<SSH_HOST>:<REMOTE_ROOT>`, where `REMOTE_ROOT` is the path to the Craft CMS project root on the remote server (the directory containing the `craft` binary). Any environment name can be used — the script will automatically look for a matching `SYNC_*` variable.

Note that `REMOTE_ROOT` must be an absolute path (e.g. `/home/user/my-craft-project`). Tilde paths (e.g. `~/my-craft-project`) will not work.

Before running the script, make sure you can connect to the remote server via SSH. If this is the first time connecting, you will be prompted to confirm the host key:

```bash
ssh user@example.com
```

## Usage

```bash
# Pull all asset volumes
./scripts/sync.sh --pull assets --from production

# Pull a specific asset volume by handle
./scripts/sync.sh --pull assets:images --from production

# Pull multiple targets
./scripts/sync.sh --pull assets:images --pull assets:documents --from production

# Pull the database
./scripts/sync.sh --pull db --from production

# Pull assets and database together
./scripts/sync.sh --pull assets --pull db --from production

# Dry run (no changes made)
./scripts/sync.sh --pull assets --pull db --from production --dry-run

# Delete files on destination that don't exist on source
./scripts/sync.sh --pull assets --from production --delete
```

## Options

| Option | Description |
|--------|-------------|
| `--pull <target>` | Target to pull. Can be `assets`, `assets:<handle>`, or `db`. Repeatable. |
| `--from <environment>` | Environment to pull from. Must match a `SYNC_*` variable in `.env`. |
| `--dry-run` | Show what would happen without making any changes. |
| `--delete` | Delete files on the destination that don't exist on the source (assets only). |

## How It Works

- Resolves asset volume paths dynamically from the Craft installation via `php craft exec`, including filesystem base paths and volume subpaths
- Skips volumes with remote filesystems (e.g. S3) that have no local path
- For database pulls, uses `php craft db/backup` on the remote server, downloads the backup via `rsync`, restores it locally, then cleans up

## After a Database Pull

After pulling a database you may want to sync your project config. Choose based on your workflow:

```bash
# Apply your local config/project/ YAML files to the restored database
php craft project-config/apply

# or

# Rebuild your local config/project/ YAML files from the restored database
php craft project-config/rebuild
```

## Notes

This is a script I made for myself to make my development life easier. It's relatively simple and straightforward, and you're free to use it as you see fit.

A few things worth mentioning:

**No push option** — I considered adding a `--push` option but decided against it to avoid potential confusion or accidents. The script is designed to live in the Craft project repository alongside your code. If you need to sync in the opposite direction, simply run the script from the other server to pull in the direction you need.

**Craft 5 only** — the script relies on Craft 5's volume and filesystem APIs. It has not been tested with earlier versions of Craft.

**Local filesystems only** — volumes using remote filesystems (e.g. Amazon S3, Google Cloud Storage) are automatically skipped, as they have no local path to sync.

## License

MIT
