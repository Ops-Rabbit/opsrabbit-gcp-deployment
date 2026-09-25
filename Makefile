TRIVY ?= trivy
PYTHON ?= python3

.PHONY: fmt fmt-check validate lint helm-test security test init init-check lock-providers check plan apply clean

HELM ?= helm
HELM_CHART ?= charts/opsrabbit
HELM_TEST_BACKEND_IMAGE ?= gcr.io/distroless/static-debian12@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HELM_TEST_WEB_IMAGE ?= gcr.io/distroless/static-debian12@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HELM_TEST_SECRET ?= opsrabbit-runtime

fmt:
	terraform fmt -recursive

fmt-check:
	terraform fmt -check -recursive

init:
	terraform init

# Refresh checksums for CI (Linux x86_64) and local Apple Silicon development.
lock-providers:
	terraform providers lock -platform=linux_amd64 -platform=darwin_arm64

init-check:
	terraform init -backend=false -input=false -lockfile=readonly

validate: init-check
	terraform validate

lint:
	tflint --init
	tflint -f compact

helm-test:
	$(HELM) lint $(HELM_CHART) --strict --set image.backend=$(HELM_TEST_BACKEND_IMAGE) --set image.web=$(HELM_TEST_WEB_IMAGE) --set secrets.existingSecret=$(HELM_TEST_SECRET)
	$(PYTHON) -m unittest tests.test_helm_chart -v
	@tmpdir=$$(mktemp -d); trap 'rm -rf "$$tmpdir"' EXIT; \
	$(HELM) template opsrabbit $(HELM_CHART) --namespace opsrabbit --set image.backend=$(HELM_TEST_BACKEND_IMAGE) --set image.web=$(HELM_TEST_WEB_IMAGE) --set secrets.existingSecret=$(HELM_TEST_SECRET) > "$$tmpdir/rendered.yaml"; \
	$(TRIVY) config --exit-code 1 --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --skip-check-update --misconfig-scanners kubernetes "$$tmpdir/rendered.yaml"

security:
	@echo "Scanning public mode"
	$(TRIVY) config --exit-code 1 --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --skip-check-update --misconfig-scanners terraform --tf-vars tests/security.tfvars.example --skip-dirs .terraform .
	@echo "Scanning private mode"
	$(TRIVY) config --exit-code 1 --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --skip-check-update --misconfig-scanners terraform --tf-vars tests/security-private.tfvars.example --skip-dirs .terraform .

test: init-check helm-test
	terraform test
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

check: fmt-check validate lint security test

plan:
	terraform plan -out=bootstrap.tfplan

apply:
	terraform apply bootstrap.tfplan
	rm -f bootstrap.tfplan

clean:
	rm -rf .terraform *.tfplan
