TRIVY ?= trivy
PYTHON ?= python3

.PHONY: fmt fmt-check validate lint security test init init-check lock-providers check plan apply clean

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

security:
	@echo "Scanning public mode"
	$(TRIVY) config --exit-code 1 --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --skip-check-update --misconfig-scanners terraform --tf-vars tests/security.tfvars.example --skip-dirs .terraform .
	@echo "Scanning private mode"
	$(TRIVY) config --exit-code 1 --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --skip-check-update --misconfig-scanners terraform --tf-vars tests/security-private.tfvars.example --skip-dirs .terraform .

test: init-check
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
