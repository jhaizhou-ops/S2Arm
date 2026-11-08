# native-test-nvn_mesh：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_mesh
ifeq ($(shell uname -s),Darwin)
# NVN2 任务 / 网格绘制（DrawMeshTasks / DrawMeshTasksIndirect，11-05 时之笛）：夹具库按 KIND 编三份（任务 / 有任务的网格 / 无任务的网格），经产品的 draw() 画到离屏目标读回列掩码。
#   两套后端（Metal 4、NXGAL_BE=mtl3 强制 Metal 3）× 编码线程（录制回放）关 / 开 各跑一遍
NVN_MESH_LIB := $(BUILD)/tests/mesh
$(NVN_MESH_LIB)/1111111111111111_b.metallib: graphics/nvn/tests/t_nvn_mesh.metal
	@mkdir -p $(dir $@)
	xcrun -sdk macosx metal -DKIND=1 $< -o $@
$(NVN_MESH_LIB)/2222222222222222_b.metallib: graphics/nvn/tests/t_nvn_mesh.metal
	@mkdir -p $(dir $@)
	xcrun -sdk macosx metal -DKIND=2 $< -o $@
$(NVN_MESH_LIB)/3333333333333333_b.metallib: graphics/nvn/tests/t_nvn_mesh.metal
	@mkdir -p $(dir $@)
	xcrun -sdk macosx metal -DKIND=3 $< -o $@
	cp $@ $(NVN_MESH_LIB)/4444444444444444_b.metallib
$(BUILD)/tests/t_nvn_mesh: graphics/nvn/tests/t_nvn_mesh.m graphics/nvn/gfx/nvn/nvn_mtl.m graphics/nvn/gfx/nvn/nvn_geometry.inc graphics/nvn/gfx/nvn/nvn_rec.h graphics/nvn/gfx/nvn/nvn2_cmd.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_mesh.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
NVN_MESH_LIBS := $(addprefix $(NVN_MESH_LIB)/,1111111111111111_b.metallib 2222222222222222_b.metallib 3333333333333333_b.metallib)
.PHONY: native-test-nvn_mesh
native-test-nvn_mesh: $(BUILD)/tests/t_nvn_mesh $(NVN_MESH_LIBS)
	DM_NVN_ENC_THREAD=0 T_MESH_LIB=$(abspath $(NVN_MESH_LIB)) timeout 120 $(BUILD)/tests/t_nvn_mesh
	DM_NVN_ENC_THREAD=1 T_MESH_LIB=$(abspath $(NVN_MESH_LIB)) timeout 120 $(BUILD)/tests/t_nvn_mesh
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=0 T_MESH_LIB=$(abspath $(NVN_MESH_LIB)) timeout 120 $(BUILD)/tests/t_nvn_mesh
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=1 T_MESH_LIB=$(abspath $(NVN_MESH_LIB)) timeout 120 $(BUILD)/tests/t_nvn_mesh
TEST_TARGETS += native-test-nvn_mesh
endif
