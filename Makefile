.PHONY: fmt fmt-check validate lint security test init init-check check plan apply clean

fmt:
	terraform fmt -recursive

fmt-check:
	terraform fmt -check -recursive

init:
	terraform init

init-check:
	terraform init -backend=false

validate: init-check
	terraform validate

lint:
	tflint --init
	tflint -f compact

security:
	tfsec .

test: init-check
	terraform test
	python3 -m unittest discover -s tests -p 'test_*.py' -v

check: fmt-check validate lint security test

plan:
	terraform plan -out=bootstrap.tfplan

apply:
	terraform apply bootstrap.tfplan
	rm -f bootstrap.tfplan

clean:
	rm -rf .terraform *.tfplan
