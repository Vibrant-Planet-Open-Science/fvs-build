#!/usr/bin/env bash
# Parse github.workflow_ref into owner/repo and git ref for checkout.
# Expected shape: <owner>/<repo>/.github/workflows/<file>@<ref>
set -euo pipefail

FVS_BUILD_REPO="${WF_REF%%/.github/*}"
FVS_BUILD_REF="${WF_REF##*@}"
if [ -z "${FVS_BUILD_REPO}" ] \
  || [ -z "${FVS_BUILD_REF}" ] \
  || [ "${FVS_BUILD_REPO}" = "${WF_REF}" ]; then
  echo "ERROR: could not parse fvs-build repo/ref from workflow_ref='${WF_REF}'" >&2
  exit 1
fi

{
  echo "repo=${FVS_BUILD_REPO}"
  echo "ref=${FVS_BUILD_REF}"
} >>"${GITHUB_OUTPUT}"

echo "fvs-build repo: ${FVS_BUILD_REPO}"
echo "fvs-build ref:  ${FVS_BUILD_REF}"
