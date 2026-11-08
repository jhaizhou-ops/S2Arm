# 自愿开发工具入口；host / test / ios 不依赖这些目标。
# 只有开发者手动运行 style-setup 才安装依赖；门禁、列车和出包不调用它。
STYLE_PYTHON ?= $(BUILD)/style-venv/bin/python
STYLE_BASE ?= origin/main
STYLE_ARGS ?= --base "$(STYLE_BASE)"

.PHONY: style-setup format format-check lint
style-setup:
	python3 -m venv "$(BUILD)/style-venv"
	"$(STYLE_PYTHON)" -m pip install --require-hashes -r tools/style-requirements.txt

format:
	"$(STYLE_PYTHON)" tools/style.py format $(STYLE_ARGS)

format-check:
	"$(STYLE_PYTHON)" tools/style.py check $(STYLE_ARGS)

lint:
	"$(STYLE_PYTHON)" tools/style.py lint $(STYLE_ARGS)
