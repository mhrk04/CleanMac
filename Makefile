# CleanMac -- developer convenience targets.
# Real logic lives in scripts/; these are thin, discoverable entry points.

.DEFAULT_GOAL := help
.PHONY: help setup project build release test doctor notarize

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup: ## One-time clone bootstrap: hooks path, commit template, GPG signing
	@bash scripts/setup.sh

project: ## Generate CleanMac.xcodeproj from project.yml
	@xcodegen generate

build: ## Debug build (ad-hoc signed, no certificate needed)
	@bash scripts/build.sh

release: ## Release build (requires a Developer ID certificate)
	@bash scripts/build.sh --release

test: ## Run the XCTest suite via xcodebuild
	@bash scripts/build.sh --test

doctor: ## Print what this machine can sign with
	@bash scripts/build.sh --doctor

notarize: ## Archive, sign, notarize, staple and verify with Gatekeeper
	@bash scripts/notarize.sh
