#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/ssh.sh"
ssh_workspace
ssh_prod_setup
ssh_test_setup
# Both SSH endpoints are restricted by their server-side authorized_keys.
# pipefail propagates failures from either leg of the transfer.
ssh_prod_dump | ssh_test_receiver restore-candidate
echo 'Production dump successfully restored to workouts_restore_candidate only.'
echo 'workouts_test and workouts_restore_staging were not restore targets.'
