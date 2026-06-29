# `make verify` is the definition of done: every quality gate green from a clean
# DB, twice in a row (the second pass catches state/order leakage between gates).
.PHONY: verify gates catalog

verify:
	bash gates/run-all.sh
	@echo "--- second pass (must also be green) ---"
	bash gates/run-all.sh

# Regenerate + validate the catalog from the source-of-truth prices table.
catalog:
	python3 catalogs/generate.py catalogs/prices.yml catalogs/inua/catalog-v1.xml
