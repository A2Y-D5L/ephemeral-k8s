SHELL := /bin/bash

# The Git URL where YOU push this repo.
GIT_REPO_URL ?= https://github.com/a2y-d5l/ephemeral-k8s.git

# Branch/tag/sha to sync from
GIT_REVISION ?= main

# Kind cluster name
CLUSTER_NAME ?= ephem

# kgateway version (pinned for reproducibility; override if desired)
KGATEWAY_VERSION ?= v2.1.2

# Gateway API CRD version (pinned for reproducibility; override if desired)
GATEWAY_API_VERSION ?= v1.4.0

# ----------------------

export GIT_REPO_URL
export GIT_REVISION
export CLUSTER_NAME
export KGATEWAY_VERSION
export GATEWAY_API_VERSION

.PHONY: up down

up:
	@./hack/up.sh

down:
	@./hack/down.sh