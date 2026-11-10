#!/usr/bin/env bash
set -euo pipefail
owner=10000000-0000-4000-8000-000000000001
first=10000000-0000-4000-8000-000000000002
second=10000000-0000-4000-8000-000000000003
psql -v ON_ERROR_STOP=1 -q -c "insert into auth.users(id,aud,role) values ('$owner','authenticated','authenticated'),('$first','authenticated','authenticated'),('$second','authenticated','authenticated')"
code=$(psql -v ON_ERROR_STOP=1 -qAt -c "set role authenticated; select set_config('request.jwt.claim.sub','$owner',false); select public.babyfeeding_family_create('father')->>'code'" | tail -1)
[[ "$code" =~ ^[0-9]{6}$ ]]
claim() {
  psql -v ON_ERROR_STOP=1 -qAt -c "set role authenticated; select set_config('request.jwt.claim.sub','$1',false); select public.babyfeeding_family_join('mother','$code',null)->>'ok'" | tail -1 > "$2"
}
claim "$first" "$RUNNER_TEMP/babyfeeding-claim-1" & a=$!
claim "$second" "$RUNNER_TEMP/babyfeeding-claim-2" & b=$!
wait "$a"
wait "$b"
results=$(cat "$RUNNER_TEMP/babyfeeding-claim-1" "$RUNNER_TEMP/babyfeeding-claim-2" | sort | tr '\n' ' ')
[[ "$results" == 'false true ' ]] || { echo 'Concurrent code use did not yield exactly one successful join'; exit 1; }
echo 'Concurrent invitation single-use test passed'
