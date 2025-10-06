#!/bin/bash

PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

# === Configuration ===
BACKUP_DIR="/backups" # Change to your actual backup directory
### BACKUP_DIR="/root/backups" # Change to your test backup directory
WEEKLY_FULL_BACKUP_DIR="${BACKUP_DIR}/WEEKLYFULL" # Directory for weekly full backups
UPLOAD_DIR="${BACKUP_DIR}/uploadtoaws" # Directory for files to be uploaded to AWS S3
TODAY=$(date +%Y-%m-%d) # Current date in YYYY-MM-DD format
DAY_OF_WEEK=$(date +%A | tr '[:upper:]' '[:lower:]') # Current day of week in lowercase
BACKUP_RETENTION_DAYS=8 # Days to keep local backups before deletion
RENAME_AFTER_DAYS=6
COPY_TO_S3_DAYS=1

# Regex patterns for valid backup filenames
REGEX_DATE_PREFIX="^[0-9]{4}-[0-9]{2}-[0-9]{2}" # Matches YYYY-MM-DD at start of filename
REGEX_DAILY_BKP="^(monday|tuesday|wednesday|thursday|friday|saturday|sunday)(-[0-9]+)?$" # Matches day-of-week names with optional -N suffix
REGEX_DAILY_BKP_DATE="^[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]+)?$"   # Matches YYYY-MM-DD with optional -N suffix
REGEX_WEEKLY_FULL_BKP="^fullbackup[0-9]+(-[0-9]+)?$" # Matches fullbackupN or fullbackupN-M
REGEX_WEEKLY_FULL_BKP_DATE="^[0-9]{4}-[0-9]{2}-[0-9]{2}-fullbackup[0-9]+(-[0-9]+)?$" # Matches YYYY-MM-DD-fullbackupN or YYYY-MM-DD-fullbackupN-M


mkdir -p "$UPLOAD_DIR"

# === Check for valid backup file names ===
is_valid_backup_file() {
    filename=$(basename "$1")
    [[ "$filename" =~ $REGEX_DAILY_BKP || \
       "$filename" =~ $REGEX_DAILY_BKP_DATE || \
       "$filename" =~ $REGEX_WEEKLY_FULL_BKP || \
       "$filename" =~ $REGEX_WEEKLY_FULL_BKP_DATE ]]
}

# === Get file creation/modification date in YYYY-MM-DD ===
get_file_date() {
    stat -c "%y" "$1" | cut -d' ' -f1
}

# === Convert date string to epoch ===
to_epoch() {
    date -d "$1" +%s
}

# === Get N days ago in epoch ===
days_ago_epoch() {
    date -d "$1 days ago" +%s
}

# === Move file with timestamps preserved ===
move_preserve_timestamp() {
    src="$1"
    dst="$2"
    #cp -p "$src" "$dst" && rm "$src"
    mv "$src" "$dst" # mv preserves timestamps by default
}


# === Rename old day-of-week files to date-based ===
rename_old_day_files() {
    for dow in monday tuesday wednesday thursday friday saturday sunday; do
        files=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${dow}*" ! -name "*-eom")

        # Get base file and save its date after testing it exists
        base_file="$BACKUP_DIR/$dow"
        [ -e "$base_file" ] || continue
        file_date=$(get_file_date "$base_file")

        for file in $files; do
            is_valid_backup_file "$file" || continue

            file_epoch=$(to_epoch "$file_date")
            cutoff_epoch=$(days_ago_epoch "$RENAME_AFTER_DAYS")

            if [[ "$file_epoch" -lt "$cutoff_epoch" ]]; then
                base_name=$(basename "$file")
                suffix="${base_name#$dow}"
                newname="${file_date}${suffix}"
                move_preserve_timestamp "$file" "$BACKUP_DIR/$newname"
                echo "Renamed $file → $newname"
            fi
        done
    done
}

# === Copy recent files for upload (last 36 hours), renaming with today's date ===
copy_recent_files_for_upload() {
    copy_to_s3_mins=$((COPY_TO_S3_DAYS * 24 * 60))

    # Process recent files in main backup dir
    while IFS= read -r -d '' file; do
        is_valid_backup_file "$file" || continue
        [ -e "$file" ] || continue

        filename=$(basename "$file")

        if [[ "$filename" =~ ^(monday|tuesday|wednesday|thursday|friday|saturday|sunday)(-[0-9]+)?$ ]]; then
            # Strip trailing -N to get base file and its date
            base_file=$(echo "$file" | sed 's/-[0-9]\{1,\}$//')
            file_date=$(get_file_date "$base_file")
            [ -z "$file_date" ] && continue

            suffix="${filename#${filename%%-*}}"
            [ "$filename" == "${filename%%-*}" ] && suffix=""
            newname="${file_date}${suffix}"

        elif [[ "$filename" =~ $REGEX_DAILY_BKP_DATE ]]; then
            # Already date-named: keep name
            newname="$filename"
        else
            continue
        fi

        if ! [ -e "$UPLOAD_DIR/$newname" ]; then
            cp -a "$file" "$UPLOAD_DIR/$newname"
            echo "Copied $file → $UPLOAD_DIR/$newname"
        else
            echo "$newname already exists in $UPLOAD_DIR, skipping."
        fi
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -mmin -"$copy_to_s3_mins" -print0)

    # Also process recent files in WEEKLYFULL (if the dir exists)
    if [ -d "$BACKUP_DIR/WEEKLYFULL" ]; then
        while IFS= read -r -d '' file; do
            is_valid_backup_file "$file" || continue
            [ -e "$file" ] || continue

            filename=$(basename "$file")
            if [[ "$filename" =~ $REGEX_WEEKLY_FULL_BKP ]]; then
                file_date=$(get_file_date "$file")
                [ -z "$file_date" ] && continue

                suffix="${filename#fullbackup}"
                newname="${file_date}-fullbackup${suffix}"
             else
                # ignore day-of-week names here (not expected in WEEKLYFULL)
                continue
            fi

            if ! [ -e "$UPLOAD_DIR/$newname" ]; then
                cp -a "$file" "$UPLOAD_DIR/$newname"
                echo "Copied $file → $UPLOAD_DIR/$newname"
            else
                echo "$newname already exists in $UPLOAD_DIR, skipping."
            fi
        done < <(find "$BACKUP_DIR/WEEKLYFULL" -maxdepth 1 -type f -mmin -"$copy_to_s3_mins" -print0 2>/dev/null)
    fi
}

# === Delete old files (>15 days) that are valid backup files and not -eom ===
delete_old_files() {
    while IFS= read -r -d '' file; do
        is_valid_backup_file "$file" || continue
        echo "Deleting $file"
        rm "$file"
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -mtime +"$BACKUP_RETENTION_DAYS" ! -name "*-eom" -print0 2>/dev/null)
}


move_to_aws_s3() {

    while IFS= read -r -d '' file; do
            
        is_valid_backup_file "$file" || continue
        [ -e "$file" ] || continue
            
        # extract YYYY-MM-DD from filename and ignore any trailing -N or -NN
        base=$(basename "$file")
            
        if [[ "$base" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
                file_date="${BASH_REMATCH[1]}"
        else
        # fallback to file metadata if name doesn't contain a date
                file_date=$(get_file_date "$file")
        fi

        if ! [[ "$base" =~ $REGEX_WEEKLY_FULL_BKP_DATE ]] ; then
            backup_type="Daily"
        else
            backup_type="WeeklyFull" 
        fi

        aws s3 mv "$file" s3://pacemisbackups/"$backup_type"/"$file_date"/ --storage-class INTELLIGENT_TIERING --profile miss3backup --no-progress
        if [ $? -ne 0 ]; then
            echo "Failed to upload $file to S3"
        fi   

    done < <(find "$BACKUP_DIR/uploadtoaws" -maxdepth 1 -type f -print0 2>/dev/null)

}

# === Execute all tasks ===


# based on the first file date without the -
# Rename day-of-week files older than 6 days to date-based format YYYY-MM-DD[-N].
# Preserves file suffix (e.g. -1, -2) and original timestamps.
# Only affects files named like monday, tuesday-1, etc.
# Does not modify files already using date-formatted names.
echo "---=== `date "+%D @ %T"` - Renaming backups older than $RENAME_AFTER_DAYS days... ===---\n\n"
rename_old_day_files

# based on the first file date without the -
# Copy recent backup files (any file from the last 36h) to upload folder,
# renamed with today's date while preserving original order and timestamps.
# Only copies files named as day-of-week or YYYY-MM-DD[-N]. (as should be 4/17)
echo "---=== `date "+%D @ %T"` - Copying recent backups for upload... ===---\n\n"
copy_recent_files_for_upload

# Upload files in uploadtoaws folder to AWS S3 and delete local copy if successful.
echo "---=== `date "+%D @ %T"` - Uploading backups to AWS S3... ===---\n\n"
move_to_aws_s3

# Delete files older than 15 days (excluding end of month *-eom files).
# Only deletes files named as day-of-week or YYYY-MM-DD[-N].
echo "---=== `date "+%D @ %T"` - Deleting backups older than $BACKUP_RETENTION_DAYS days... ===---\n\n"
delete_old_files
 
