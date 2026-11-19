#!/bin/sh
#MISE description="This repository's own checks"
# check:repo depends on this task, so it stays a file. A repository lists its
# own checks in depends, each a task that runs one tool; the dependencies run
# in parallel. A starter: the template writes this file once and never
# rewrites it.
#
# Each check listed here must also run on Linux, where a documentation-only
# pull request runs check:repo.
