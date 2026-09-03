#!/bin/sh
set -eu

dabstep_revision=9cef9a2976ccce4d306bf220604597788b090d43
payments_sha256=5fbb26210a45427d7a6560cfab3a362a08e4067f27cd03695f211a51c47ffc25
dev_sha256=c1da755a6fe9cb538fc84719f51e1db0bff0190a1d6905767ac18c755e66a07b
manual_sha256=bb7f4ca6fdc759af1f480702b3a3b12e17e9293b0d38a1dbfbbc8ffc1e572d2c
payments_readme_sha256=8754b92d0b3127856ff72266ea482995d2a1f6a34d0a12732f7c26f527f2c4a5
payments_url="https://huggingface.co/datasets/adyen/DABstep/resolve/${dabstep_revision}/data/context/payments.csv"
dev_url="https://huggingface.co/datasets/adyen/DABstep/resolve/${dabstep_revision}/data/tasks/dev.jsonl"
manual_url="https://huggingface.co/datasets/adyen/DABstep/resolve/${dabstep_revision}/data/context/manual.md"
payments_readme_url="https://huggingface.co/datasets/adyen/DABstep/resolve/${dabstep_revision}/data/context/payments-readme.md"

mkdir -p data reference/context

payments_tmp="data/payments.csv.tmp.$$"
dev_tmp="reference/dev.jsonl.tmp.$$"
manual_tmp="reference/context/manual.md.tmp.$$"
payments_readme_tmp="reference/context/payments-readme.md.tmp.$$"

cleanup() {
  rm -f "$payments_tmp" "$dev_tmp" "$manual_tmp" "$payments_readme_tmp"
}

trap cleanup EXIT HUP INT TERM

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

require_hash() {
  expected=$1
  file=$2
  actual=$(sha256 "$file")

  if [ "$actual" != "$expected" ]; then
    printf 'checksum mismatch for %s\nexpected: %s\nactual:   %s\n' "$file" "$expected" "$actual" >&2
    exit 1
  fi
}

curl --fail --location --show-error "$payments_url" -o "$payments_tmp"
curl --fail --location --show-error "$dev_url" -o "$dev_tmp"
curl --fail --location --show-error "$manual_url" -o "$manual_tmp"
curl --fail --location --show-error "$payments_readme_url" -o "$payments_readme_tmp"

require_hash "$payments_sha256" "$payments_tmp"
require_hash "$dev_sha256" "$dev_tmp"
require_hash "$manual_sha256" "$manual_tmp"
require_hash "$payments_readme_sha256" "$payments_readme_tmp"

expected_header='psp_reference,merchant,card_scheme,year,hour_of_day,minute_of_hour,day_of_year,is_credit,eur_amount,ip_country,issuing_country,device_type,ip_address,email_address,card_number,shopper_interaction,card_bin,has_fraudulent_dispute,is_refused_by_adyen,aci,acquirer_country'
actual_header=$(sed -n '1p' "$payments_tmp")

if [ "$actual_header" != "$expected_header" ]; then
  printf '%s\n' 'payments.csv header does not match the pinned schema' >&2
  exit 1
fi

line_count=$(wc -l < "$payments_tmp" | tr -d ' ')
if [ "$line_count" != 138237 ]; then
  printf 'payments.csv line count mismatch: expected 138237, got %s\n' "$line_count" >&2
  exit 1
fi

if ! grep -Fx 'Fraud is defined as the ratio of fraudulent volume over total volume.' \
  "$manual_tmp" >/dev/null; then
  printf '%s\n' 'DABStep manual fraud definition does not match the pinned context' >&2
  exit 1
fi

mv "$payments_tmp" data/payments.csv
mv "$dev_tmp" reference/dev.jsonl
mv "$manual_tmp" reference/context/manual.md
mv "$payments_readme_tmp" reference/context/payments-readme.md
