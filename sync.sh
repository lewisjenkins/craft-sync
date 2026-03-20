#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/.env"

PULL=()
PUSH=()
FROM=""
TO=""
DRY_RUN=""
DELETE=""
PC=""

usage() {
    echo "Usage:"
    echo "  sync.sh --pull <assets|assets:handle|db> --from <environment> [--dry-run] [--delete] [--pc <apply|rebuild>]"
    echo "  sync.sh --push <assets|assets:handle|db> --to <environment>   [--dry-run] [--delete] [--pc <apply|rebuild>]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pull)    [[ -z "$2" || "$2" == --* ]] && usage
                   PULL+=("$2");             shift 2 ;;
        --push)    [[ -z "$2" || "$2" == --* ]] && usage
                   PUSH+=("$2");             shift 2 ;;
        --from)    [[ -z "$2" || "$2" == --* ]] && usage
                   FROM="$2";                shift 2 ;;
        --to)      [[ -z "$2" || "$2" == --* ]] && usage
                   TO="$2";                  shift 2 ;;
        --pc)      [[ -z "$2" || "$2" == --* ]] && usage
                   PC="$2";                  shift 2 ;;
        --dry-run) DRY_RUN=1;               shift ;;
        --delete)  DELETE=1;                shift ;;
        *)         usage ;;
    esac
done

# 1. Validate mutually exclusive options
[[ ${#PULL[@]} -gt 0 && ${#PUSH[@]} -gt 0 ]] && echo "Error: --pull and --push cannot be used together" && exit 1
[[ ${#PULL[@]} -gt 0 && -n "$TO" ]]           && echo "Error: --to is not valid with --pull" && exit 1
[[ ${#PUSH[@]} -gt 0 && -n "$FROM" ]]         && echo "Error: --from is not valid with --push" && exit 1

# 2. Validate --pull and --from, or --push and --to are present
[[ ${#PULL[@]} -eq 0 && ${#PUSH[@]} -eq 0 ]] && usage
[[ ${#PULL[@]} -gt 0 && -z "$FROM" ]] && usage
[[ ${#PUSH[@]} -gt 0 && -z "$TO" ]]   && usage

# 3. Validate --pc value if provided
[[ -n "$PC" && "$PC" != "apply" && "$PC" != "rebuild" ]] \
    && echo "Error: --pc must be 'apply' or 'rebuild'" && exit 1

# 4. Resolve SYNC_* from .env
ENV=${FROM:-$TO}
SYNC_VAR="SYNC_${ENV^^}"
SYNC_VALUE="${!SYNC_VAR}"
[[ -z "$SYNC_VALUE" ]] && echo "Error: ${SYNC_VAR} is not set in .env" && exit 1
SSH_HOST="${SYNC_VALUE%%:*}"
REMOTE_ROOT="${SYNC_VALUE#*:}"

# 5. Test SSH connection
echo "Connecting to $SSH_HOST..."
ssh -q -o BatchMode=yes -o ConnectTimeout=5 $SSH_HOST exit 2>/dev/null \
    || { echo "Error: Cannot connect to $SSH_HOST"; exit 1; }

# 6. Validate remote Craft installation
echo "Validating remote Craft installation..."
REMOTE_CRAFT_CHECK=$(ssh $SSH_HOST "cd $REMOTE_ROOT && php craft exec \"echo 1;\"" 2>/dev/null | grep -c '1' || true)
[[ "$REMOTE_CRAFT_CHECK" -eq 0 ]] && echo "Error: No valid Craft installation found at $REMOTE_ROOT on $SSH_HOST" && exit 1

# 7. Validate local Craft installation
echo "Validating local Craft installation..."
LOCAL_CRAFT_CHECK=$(php "$SCRIPT_DIR/craft" exec "echo 1;" 2>/dev/null | grep -c '1' || true)
[[ "$LOCAL_CRAFT_CHECK" -eq 0 ]] && echo "Error: No valid Craft installation found at $SCRIPT_DIR" && exit 1

# Resolve remote volume paths, optionally filtered by handle
remote_volumes() {
    local HANDLE=$1
    ssh $SSH_HOST "cd $REMOTE_ROOT && php craft exec \"foreach (Craft::\\\$app->volumes->getAllVolumes() as \\\$v) { \\\$fs = \\\$v->getFs(); if (!isset(\\\$fs->path)) continue; \\\$base = Craft::getAlias(\\\$fs->path); \\\$sub = \\\$v->subpath ?? ''; \\\$path = rtrim(\\\$base, '/') . (\\\$sub ? '/' . ltrim(\\\$sub, '/') : ''); if ('$HANDLE' === '' || \\\$v->handle === '$HANDLE') echo \\\$v->handle . ':' . \\\$path . PHP_EOL; }\"" 2>/dev/null | grep ':/'
}

# Resolve local volume paths, optionally filtered by handle
local_volumes() {
    local HANDLE=$1
    php "$SCRIPT_DIR/craft" exec "foreach (Craft::\$app->volumes->getAllVolumes() as \$v) { \$fs = \$v->getFs(); if (!isset(\$fs->path)) continue; \$base = Craft::getAlias(\$fs->path); \$sub = \$v->subpath ?? ''; \$path = rtrim(\$base, '/') . (\$sub ? '/' . ltrim(\$sub, '/') : ''); if ('$HANDLE' === '' || \$v->handle === '$HANDLE') echo \$v->handle . ':' . \$path . PHP_EOL; }" 2>/dev/null | grep ':/'
}

pull_assets() {
    local HANDLE=$1
    RSYNC_OPTS="-avz"
    [[ -n "$DRY_RUN" ]] && RSYNC_OPTS="$RSYNC_OPTS --dry-run"
    [[ -n "$DELETE" ]]  && RSYNC_OPTS="$RSYNC_OPTS --delete"

    REMOTE_VOLS=$(remote_volumes "$HANDLE" || true)
    [[ -z "$REMOTE_VOLS" ]] && echo "Error: No matching remote volumes found${HANDLE:+ for handle '$HANDLE'}" && exit 1

    LOCAL_VOLS=$(local_volumes "$HANDLE" || true)
    [[ -z "$LOCAL_VOLS" ]] && echo "Error: No matching local volumes found${HANDLE:+ for handle '$HANDLE'}" && exit 1

    while IFS=':' read -r handle remote_path; do
        local_path=$(echo "$LOCAL_VOLS" | grep "^$handle:" | cut -d':' -f2)
        [[ -z "$local_path" ]] && echo "Error: No local volume found for handle '$handle'" && exit 1
        echo "Syncing volume: $handle"
        rsync $RSYNC_OPTS $SSH_HOST:$remote_path/ $local_path/
    done <<< "$REMOTE_VOLS"

    [[ -n "$DRY_RUN" ]] && echo "Dry run complete." || echo "Done."
}

push_assets() {
    local HANDLE=$1
    RSYNC_OPTS="-avz"
    [[ -n "$DRY_RUN" ]] && RSYNC_OPTS="$RSYNC_OPTS --dry-run"
    [[ -n "$DELETE" ]]  && RSYNC_OPTS="$RSYNC_OPTS --delete"

    REMOTE_VOLS=$(remote_volumes "$HANDLE" || true)
    [[ -z "$REMOTE_VOLS" ]] && echo "Error: No matching remote volumes found${HANDLE:+ for handle '$HANDLE'}" && exit 1

    LOCAL_VOLS=$(local_volumes "$HANDLE" || true)
    [[ -z "$LOCAL_VOLS" ]] && echo "Error: No matching local volumes found${HANDLE:+ for handle '$HANDLE'}" && exit 1

    while IFS=':' read -r handle remote_path; do
        local_path=$(echo "$LOCAL_VOLS" | grep "^$handle:" | cut -d':' -f2)
        [[ -z "$local_path" ]] && echo "Error: No local volume found for handle '$handle'" && exit 1
        echo "Syncing volume: $handle"
        rsync $RSYNC_OPTS $local_path/ $SSH_HOST:$remote_path/
    done <<< "$REMOTE_VOLS"

    [[ -n "$DRY_RUN" ]] && echo "Dry run complete." || echo "Done."
}

pull_db() {
    REMOTE_STORAGE=$(ssh $SSH_HOST "cd $REMOTE_ROOT && php craft exec \"echo Craft::\\\$app->path->getStoragePath();\"" 2>/dev/null | grep '^/')
    [[ -z "$REMOTE_STORAGE" ]] && echo "Error: Could not resolve remote storage path" && exit 1

    LOCAL_STORAGE=$(php "$SCRIPT_DIR/craft" exec "echo Craft::\$app->path->getStoragePath();" 2>/dev/null | grep '^/')
    [[ -z "$LOCAL_STORAGE" ]] && echo "Error: Could not resolve local storage path" && exit 1

    echo "Backing up remote database..."
    ssh $SSH_HOST "cd $REMOTE_ROOT && php craft db/backup" \
        || { echo "Error: Remote database backup failed"; exit 1; }

    echo "Finding backup..."
    REMOTE_BACKUP=$(ssh $SSH_HOST "ls -t $REMOTE_STORAGE/backups/ | head -1")
    [[ -z "$REMOTE_BACKUP" ]] && echo "Error: Could not find remote backup file" && exit 1

    echo "Downloading backup..."
    rsync $SSH_HOST:$REMOTE_STORAGE/backups/$REMOTE_BACKUP $LOCAL_STORAGE/backups/ \
        || { echo "Error: Failed to download backup"; exit 1; }

    echo "Cleaning up remote backup..."
    ssh $SSH_HOST "rm -f $REMOTE_STORAGE/backups/$REMOTE_BACKUP"

    if [[ -n "$DRY_RUN" ]]; then
        echo "Dry run: $ENV database backup downloaded and verified successfully."
        echo "Cleaning up local backup..."
        rm -f $LOCAL_STORAGE/backups/$REMOTE_BACKUP
        echo "Dry run complete."
        return
    fi

    echo "Restoring local database..."
    php "$SCRIPT_DIR/craft" db/restore $LOCAL_STORAGE/backups/$REMOTE_BACKUP --drop-all-tables --interactive=0 \
        || { echo "Error: Local database restore failed"; exit 1; }

    rm -f $LOCAL_STORAGE/backups/$REMOTE_BACKUP

    echo "Done."

    case "$PC" in
        apply)   echo "Applying project config..."
                 php "$SCRIPT_DIR/craft" project-config/apply ;;
        rebuild) echo "Rebuilding project config..."
                 php "$SCRIPT_DIR/craft" project-config/rebuild ;;
    esac
}

push_db() {
    REMOTE_STORAGE=$(ssh $SSH_HOST "cd $REMOTE_ROOT && php craft exec \"echo Craft::\\\$app->path->getStoragePath();\"" 2>/dev/null | grep '^/')
    [[ -z "$REMOTE_STORAGE" ]] && echo "Error: Could not resolve remote storage path" && exit 1

    LOCAL_STORAGE=$(php "$SCRIPT_DIR/craft" exec "echo Craft::\$app->path->getStoragePath();" 2>/dev/null | grep '^/')
    [[ -z "$LOCAL_STORAGE" ]] && echo "Error: Could not resolve local storage path" && exit 1

    echo "Backing up local database..."
    php "$SCRIPT_DIR/craft" db/backup \
        || { echo "Error: Local database backup failed"; exit 1; }

    echo "Finding backup..."
    LOCAL_BACKUP=$(ls -t $LOCAL_STORAGE/backups/ | head -1)
    [[ -z "$LOCAL_BACKUP" ]] && echo "Error: Could not find local backup file" && exit 1

    echo "Uploading backup..."
    rsync $LOCAL_STORAGE/backups/$LOCAL_BACKUP $SSH_HOST:$REMOTE_STORAGE/backups/ \
        || { echo "Error: Failed to upload backup"; exit 1; }

    echo "Cleaning up local backup..."
    rm -f $LOCAL_STORAGE/backups/$LOCAL_BACKUP

    if [[ -n "$DRY_RUN" ]]; then
        echo "Dry run: $ENV database backup uploaded and verified successfully."
        echo "Cleaning up remote backup..."
        ssh $SSH_HOST "rm -f $REMOTE_STORAGE/backups/$LOCAL_BACKUP"
        echo "Dry run complete."
        return
    fi

    echo "Restoring remote database..."
    ssh $SSH_HOST "cd $REMOTE_ROOT && php craft db/restore $REMOTE_STORAGE/backups/$LOCAL_BACKUP --drop-all-tables --interactive=0" \
        || { echo "Error: Remote database restore failed"; exit 1; }

    ssh $SSH_HOST "rm -f $REMOTE_STORAGE/backups/$LOCAL_BACKUP"

    echo "Done."

    case "$PC" in
        apply)   echo "Applying project config..."
                 ssh $SSH_HOST "cd $REMOTE_ROOT && php craft project-config/apply" ;;
        rebuild) echo "Rebuilding project config..."
                 ssh $SSH_HOST "cd $REMOTE_ROOT && php craft project-config/rebuild" ;;
    esac
}

# 8. Process each target
if [[ ${#PULL[@]} -gt 0 ]]; then
    for target in "${PULL[@]}"; do
        case "$target" in
            assets:*)  pull_assets "${target#assets:}" ;;
            assets)    pull_assets "" ;;
            db)        pull_db ;;
            *)         echo "Unknown target: $target"; exit 1 ;;
        esac
    done
fi

if [[ ${#PUSH[@]} -gt 0 ]]; then
    for target in "${PUSH[@]}"; do
        case "$target" in
            assets:*)  push_assets "${target#assets:}" ;;
            assets)    push_assets "" ;;
            db)        push_db ;;
            *)         echo "Unknown target: $target"; exit 1 ;;
        esac
    done
fi
