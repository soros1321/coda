#!/bin/bash

set -e

trap 'kill $(jobs -p)' EXIT
cd "$(dirname "$0")"/../../

eval `opam config env` && jbuilder build >> /app/logs 2>&1

_build/install/default/bin/mnt_cycle_search >> /app/logs 2>&1 &

wait
