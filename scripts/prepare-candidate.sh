#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/ssh.sh"
ssh_workspace
ssh_test_setup
ssh_test_receiver prepare-candidate
