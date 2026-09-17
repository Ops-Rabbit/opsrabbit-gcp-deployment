.PHONY: fmt validate lint security test init plan bootstrap deploy clean

fmt:
	terraform fmt -recursive

fmt-check:
	terraform fmt -check -recursive

init:
	terraform init

validate: init
	terraform validate

lint:
	tflint --init
	tflint -f compact

security:
	tfsec .

test: init
	terraform test

check: fmt-check validate lint security test

plan:
	terraform plan -out=bootstrap.tfplan

apply:
	terraform apply bootstrap.tfplan
	rm -f bootstrap.tfplan

clean:
	rm -rf .terraform *.tfplan
