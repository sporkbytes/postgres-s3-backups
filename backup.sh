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
    region=$1
    shift
    aws s3 --region "$region" "$@"
}

s3api() {
    region=$1
    bucket=$2
    action=$3
    shift 3
    aws s3api "$action" --region "$region" --bucket "$bucket" "$@"
}

bucket_exists() {
    region=$1
    bucket=$2
    s3 "$region" ls "s3://$bucket" >/dev/null 2>&1
}

create_bucket() {
    region=$1
    bucket=$2

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
    region=$1
    bucket=$2
    if bucket_exists "$region" "$bucket"; then
        return
    fi
    create_bucket "$region" "$bucket"
}

ensure_all_buckets_exist() {
    i=1
    while [ "$i" -le "$TARGET_COUNT" ]; do
        ensure_bucket_exists "$(target_region "$i")" "$(target_bucket "$i")"
        i=$((i + 1))
    done
}

pg_dump_database() {
    pg_dump --no-owner --no-privileges --clean --if-exists --quote-all-identifiers "$DATABASE_URL"
}

upload_to_bucket() {
    region=$1
    bucket=$2
    object_key=$3
    # if the zipped backup file is larger than 50 GB add the --expected-size option
    # see https://docs.aws.amazon.com/cli/latest/reference/s3/cp.html
    s3 "$region" cp - "s3://$bucket/$object_key"
}

copy_object() {
    src_region=$1
    src_bucket=$2
    dst_region=$3
    dst_bucket=$4
    object_key=$5

    echo "Copying backup to s3://$dst_bucket/$object_key ($dst_region)..."
    # Destination --region; CLI performs cross-region copy without a full local file
    aws s3 cp \
        "s3://$src_bucket/$object_key" \
        "s3://$dst_bucket/$object_key" \
        --region "$dst_region" \
        --source-region "$src_region"
}

main() {
    parse_targets
    ensure_all_buckets_exist

    object_key=$(date +%Y/%m/%d/backup-%H-%M-%S.sql.gz)

    primary_region=$(target_region 1)
    primary_bucket=$(target_bucket 1)

    echo "Taking backup and uploading it to s3://$primary_bucket/$object_key ($primary_region)..."
    pg_dump_database | gzip | upload_to_bucket "$primary_region" "$primary_bucket" "$object_key"

    i=2
    while [ "$i" -le "$TARGET_COUNT" ]; do
        copy_object \
            "$primary_region" "$primary_bucket" \
            "$(target_region "$i")" "$(target_bucket "$i")" \
            "$object_key"
        i=$((i + 1))
    done

    echo "Done."
}

main
