#!/bin/sh

set -o errexit -o nounset -o pipefail

export AWS_PAGER=""

# Populated by parse_targets from S3_TARGETS (newline-separated parallel lists)
TARGET_REGIONS=""
TARGET_BUCKETS=""
TARGET_COUNT=0

trim() {
    # shellcheck disable=SC2001
    echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

parse_targets() {
    local old_ifs
    local pair
    local region
    local bucket

    if [ -z "${S3_TARGETS:-}" ]; then
        echo "S3_TARGETS is required (comma-separated region:bucket pairs)" >&2
        exit 1
    fi

    TARGET_REGIONS=""
    TARGET_BUCKETS=""
    TARGET_COUNT=0

    old_ifs=$IFS
    IFS=,
    # shellcheck disable=SC2086
    set -- $S3_TARGETS
    IFS=$old_ifs

    for pair in "$@"; do
        pair=$(trim "$pair")
        if [ -z "$pair" ]; then
            continue
        fi

        case "$pair" in
            *:*)
                ;;
            *)
                echo "Invalid S3_TARGETS entry '$pair' (expected region:bucket)" >&2
                exit 1
                ;;
        esac

        region=$(trim "${pair%%:*}")
        bucket=$(trim "${pair#*:}")

        case "$bucket" in
            *:*)
                echo "Invalid S3_TARGETS entry '$pair' (expected region:bucket)" >&2
                exit 1
                ;;
        esac

        if [ -z "$region" ] || [ -z "$bucket" ]; then
            echo "Invalid S3_TARGETS entry '$pair' (expected region:bucket)" >&2
            exit 1
        fi

        TARGET_REGIONS="${TARGET_REGIONS}${TARGET_REGIONS:+
}${region}"
        TARGET_BUCKETS="${TARGET_BUCKETS}${TARGET_BUCKETS:+
}${bucket}"
        TARGET_COUNT=$((TARGET_COUNT + 1))
    done

    if [ "$TARGET_COUNT" -lt 1 ]; then
        echo "S3_TARGETS must include at least one region:bucket pair" >&2
        exit 1
    fi
}

target_region() {
    echo "$TARGET_REGIONS" | sed -n "${1}p"
}

target_bucket() {
    echo "$TARGET_BUCKETS" | sed -n "${1}p"
}

s3() {
    local region=$1
    shift
    aws s3 --region "$region" "$@"
}

s3api() {
    local region=$1
    local bucket=$2
    local action=$3
    shift 3
    aws s3api "$action" --region "$region" --bucket "$bucket" "$@"
}

bucket_exists() {
    local region=$1
    local bucket=$2
    s3 "$region" ls "s3://$bucket" >/dev/null 2>&1
}

create_bucket() {
    local region=$1
    local bucket=$2

    echo "Bucket $bucket doesn't exist in $region. Creating it now..."

    if [ "$region" = "us-east-1" ]; then
        s3api "$region" "$bucket" create-bucket \
            --object-ownership BucketOwnerEnforced
    else
        s3api "$region" "$bucket" create-bucket \
            --create-bucket-configuration LocationConstraint="$region" \
            --object-ownership BucketOwnerEnforced
    fi

    s3api "$region" "$bucket" put-public-access-block \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    s3api "$region" "$bucket" put-bucket-versioning \
        --versioning-configuration Status=Enabled

    s3api "$region" "$bucket" put-bucket-encryption \
        --server-side-encryption-configuration \
        '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}'
}

ensure_bucket_exists() {
    local region=$1
    local bucket=$2
    if bucket_exists "$region" "$bucket"; then
        return
    fi
    create_bucket "$region" "$bucket"
}

ensure_all_buckets_exist() {
    local i=1
    while [ "$i" -le "$TARGET_COUNT" ]; do
        ensure_bucket_exists "$(target_region "$i")" "$(target_bucket "$i")"
        i=$((i + 1))
    done
}

pg_dump_database() {
    pg_dump --no-owner --no-privileges --clean --if-exists --quote-all-identifiers "$DATABASE_URL"
}

upload_to_bucket() {
    local region=$1
    local bucket=$2
    local object_key=$3
    # if the zipped backup file is larger than 50 GB add the --expected-size option
    # see https://docs.aws.amazon.com/cli/latest/reference/s3/cp.html
    s3 "$region" cp - "s3://$bucket/$object_key"
}

copy_object() {
    local src_region=$1
    local src_bucket=$2
    local dst_region=$3
    local dst_bucket=$4
    local object_key=$5

    echo "Copying backup to s3://$dst_bucket/$object_key ($dst_region)..."
    # Destination --region; CLI performs cross-region copy without a full local file
    aws s3 cp \
        "s3://$src_bucket/$object_key" \
        "s3://$dst_bucket/$object_key" \
        --region "$dst_region" \
        --source-region "$src_region"
}

retention_count() {
    local count=${BACKUP_RETENTION_COUNT:-7}
    case "$count" in
        ''|*[!0-9]*)
            echo "BACKUP_RETENTION_COUNT must be a positive integer (got '$count')" >&2
            exit 1
            ;;
    esac
    if [ "$count" -lt 1 ]; then
        echo "BACKUP_RETENTION_COUNT must be a positive integer (got '$count')" >&2
        exit 1
    fi
    echo "$count"
}

# Permanently delete every version and delete marker for a key.
delete_all_versions() {
    local region=$1
    local bucket=$2
    local object_key=$3
    local version_ids
    local delete_marker_ids
    local version_id

    # Filter to the exact key (prefix listing can return longer key names).
    # JMESPath string literals use backticks.
    version_ids=$(s3api "$region" "$bucket" list-object-versions \
        --prefix "$object_key" \
        --output text \
        --query "Versions[?Key==\`$object_key\`].VersionId")
    version_ids=$(echo "$version_ids" | tr '\t' '\n' | sed '/^$/d;/^None$/d')

    delete_marker_ids=$(s3api "$region" "$bucket" list-object-versions \
        --prefix "$object_key" \
        --output text \
        --query "DeleteMarkers[?Key==\`$object_key\`].VersionId")
    delete_marker_ids=$(echo "$delete_marker_ids" | tr '\t' '\n' | sed '/^$/d;/^None$/d')

    if [ -z "$version_ids" ] && [ -z "$delete_marker_ids" ]; then
        # Unversioned bucket (or object already gone): plain delete.
        s3api "$region" "$bucket" delete-object --key "$object_key" >/dev/null
        return
    fi

    # Here-doc keeps the loop in this shell so errexit/pipefail apply.
    while IFS= read -r version_id || [ -n "$version_id" ]; do
        if [ -z "$version_id" ]; then
            continue
        fi
        s3api "$region" "$bucket" delete-object \
            --key "$object_key" \
            --version-id "$version_id" >/dev/null
    done <<EOF
$version_ids
$delete_marker_ids
EOF
}

list_backup_keys() {
    local region=$1
    local bucket=$2
    local listing

    # aws s3 ls exits 1 when nothing matches; treat that as an empty list.
    listing=$(s3 "$region" ls "s3://$bucket/backup-" 2>/dev/null) || true
    if [ -z "$listing" ]; then
        return 0
    fi
    # Flat keys: "DATE TIME SIZE KEY"
    echo "$listing" | awk '{ print $4 }'
}

prune_old_backups() {
    local region=$1
    local bucket=$2
    local keep
    local keys
    local total
    local index
    local key

    keep=$(retention_count)

    keys=$(list_backup_keys "$region" "$bucket" | sort -r)
    if [ -z "$keys" ]; then
        return
    fi

    total=$(echo "$keys" | wc -l | tr -d ' ')
    if [ "$total" -le "$keep" ]; then
        echo "Retention: s3://$bucket has $total backup(s) (keep $keep); nothing to prune."
        return
    fi

    echo "Retention: pruning s3://$bucket to $keep newest backup(s)..."
    index=0
    while IFS= read -r key || [ -n "$key" ]; do
        if [ -z "$key" ]; then
            continue
        fi
        index=$((index + 1))
        if [ "$index" -le "$keep" ]; then
            echo "  keeping s3://$bucket/$key"
            continue
        fi
        echo "  deleting s3://$bucket/$key (all versions)"
        delete_all_versions "$region" "$bucket" "$key"
    done <<EOF
$keys
EOF
}

main() {
    local object_key
    local primary_region
    local primary_bucket
    local i
    local dst_region
    local dst_bucket

    parse_targets
    # Validate early so a bad env fails before dump/upload.
    retention_count >/dev/null
    ensure_all_buckets_exist

    object_key=$(date +backup-%Y-%m-%d-%H-%M-%S.sql.gz)

    primary_region=$(target_region 1)
    primary_bucket=$(target_bucket 1)

    echo "Taking backup and uploading it to s3://$primary_bucket/$object_key ($primary_region)..."
    pg_dump_database | gzip | upload_to_bucket "$primary_region" "$primary_bucket" "$object_key"
    prune_old_backups "$primary_region" "$primary_bucket"

    i=2
    while [ "$i" -le "$TARGET_COUNT" ]; do
        dst_region=$(target_region "$i")
        dst_bucket=$(target_bucket "$i")
        copy_object \
            "$primary_region" "$primary_bucket" \
            "$dst_region" "$dst_bucket" \
            "$object_key"
        prune_old_backups "$dst_region" "$dst_bucket"
        i=$((i + 1))
    done

    echo "Done."
}

main
