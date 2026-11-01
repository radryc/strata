.DEFAULT_GOAL := help

.PHONY: help up down k8s k8s-down aws onboard authentik

help:
	@printf 'Strata public bootstrap\n\n'
	@printf '  make up        local kind developer stack\n'
	@printf '  make down      tear down the local kind stack\n'
	@printf '  make k8s       deploy to the current kubeconfig (build/push with flags)\n'
	@printf '  make k8s-down  remove Strata from the current cluster\n'
	@printf '  make aws       deploy the AWS CDK stack\n'
	@printf '  make onboard   onboard an application repo (REPO=../my-app)\n'
	@printf '  make authentik  re-apply the local Authentik SSO setup\n'

up:
	./scripts/dev-kind-up.sh

down:
	./scripts/dev-kind-down.sh

k8s:
	./scripts/k8s-up.sh $(ARGS)

k8s-down:
	./scripts/k8s-down.sh $(ARGS)

aws:
	./scripts/aws-up.sh $(ARGS)

onboard:
	@test -n "$(REPO)" || (printf 'usage: make onboard REPO=../my-app [ARGS=...]\n' >&2; exit 2)
	./scripts/onboard-app.sh --repo "$(REPO)" $(ARGS)

authentik:
	./scripts/dev-kind-authentik.sh $(ARGS)
