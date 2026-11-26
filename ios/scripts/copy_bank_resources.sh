#!/bin/sh
# Populate the app bundle from the fictional examples, or from a local scrape.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
destination="$1"
source="$root/examples"
if [ "${OPTO_USE_LOCAL_BANK:-0}" = 1 ]; then
    source="$root/題庫"
fi

if [ ! -d "$source/轉檔" ] || [ -z "$(find "$source/轉檔" -name '*.json' -print -quit)" ]; then
    echo "error: No parsed questions in $source/轉檔. See the question-bank setup in README.md." >&2
    exit 1
fi

mkdir -p "$destination/轉檔"
rsync -a --delete --delete-excluded --include='*/' --include='*.json' --exclude='*' \
    "$source/轉檔/" "$destination/轉檔/"

for resource in 觀念標籤表.json 考點.json 講義.json ai_questions.json; do
    input="$source/$resource"
    if [ "$resource" = ai_questions.json ] && [ "$source" = "$root/題庫" ]; then
        input="$source/AI模擬/ai_questions.json"
    fi
    if [ -f "$input" ]; then
        cp "$input" "$destination/$resource"
    else
        rm -f "$destination/$resource"
    fi
done

if [ -d "$source/圖" ]; then
    mkdir -p "$destination/圖"
    rsync -a --delete "$source/圖/" "$destination/圖/"
else
    rm -rf "$destination/圖"
fi

if [ -d "$source/原始" ]; then
    "$root/ios/scripts/copy_exam_pdfs.sh" "$source/原始" "$destination/原始"
else
    rm -rf "$destination/原始"
fi
