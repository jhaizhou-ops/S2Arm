# 画幅线（tests/visual/）构建片段：由 tests/build.mk 包含（顶层只自动包含一级目录的 build.mk）。
# visual-test-widen：graphics/widen 单元测试（dotnet，秒级）；失败项数即退出码。
.PHONY: visual-test-widen
visual-test-widen:
	dotnet run -c Release --project tests/visual/widen_unit
TEST_TARGETS += visual-test-widen
