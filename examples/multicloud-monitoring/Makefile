EXAMPLE_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
STRATA_ROOT := $(abspath $(EXAMPLE_DIR)/../../..)
GUARDIANCTL_ARGS ?=

.PHONY: help validate apply synth deploy-aws monitoring

help:
	@printf '%s\n' \
	  'make validate     Render + validate policy and partition manifests' \
	  'make apply        Publish policy, import partitions, observe AWS' \
	  'make synth        Synthesize both AWS CDK stacks into cdk/cdk.out' \
	  'make deploy-aws   Deploy both AWS CDK stacks (needs AWS credentials)' \
	  'make monitoring   Release the platform monitoring partition'

validate:
	$(EXAMPLE_DIR)/apply.sh --validate-only

apply:
	$(EXAMPLE_DIR)/apply.sh

synth:
	cd $(EXAMPLE_DIR)/cdk && npm install --silent --no-audit --no-fund && npx cdk synth

deploy-aws:
	cd $(EXAMPLE_DIR)/cdk && npm install --silent --no-audit --no-fund && npx cdk deploy --all --require-approval never

monitoring:
	cd $(STRATA_ROOT)/guardian && ./bin/guardianctl $(GUARDIANCTL_ARGS) release run --partition monitoring --build --bump
