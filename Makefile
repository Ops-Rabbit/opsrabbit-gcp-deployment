TRIVY ?= trivy
PYTHON ?= python3

.PHONY: fmt fmt-check validate lint security test init init-check check plan apply clean

fmt:
	terraform fmt -recursive

fmt-check:
	terraform fmt -check -recursive

init:
	terraform init

init-check:
	terraform init -backend=false -input=false -lockfile=readonly

validate: init-check
	terraform validate

lint:
	tflint --init
	tflint -f compact

security:
	$(TRIVY) config --exit-code 1 --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --skip-check-update --misconfig-scanners terraform --tf-vars tests/security.tfvars.example --skip-dirs .terraform .

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
