#!/bin/zsh
# Copies the 驗光師 exam PDFs (試題／答案／更正答案) into the app bundle.
# Usage: copy_exam_pdfs.sh <source 題庫/原始> <dest bundle folder>
# 驗光生 概要 subjects are skipped. The caller checks whether the source folder exists.
set -eu
src="$1"
dst="$2"
mkdir -p "$dst"
rsync -a --delete --delete-excluded --prune-empty-dirs \
  --include='*/' \
  --include='*_眼球解剖生理學與倫理法規_*.pdf' \
  --include='*_視覺光學_*.pdf' \
  --include='*_視光學_*.pdf' \
  --include='*_隱形眼鏡學與配鏡學_*.pdf' \
  --include='*_低視力學_*.pdf' \
  --exclude='*' \
  "$src/" "$dst/"
count=$(find "$dst" -name '*.pdf' | wc -l | tr -d ' ')
echo "Copied $count exam PDFs into the app bundle"
