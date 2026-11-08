# GL GPU mip / cube 回归

`t_gpu_mip.sh` 把本目录 GLSL 经生产 `gl_shaders.py` 编译出库，链接生产宿主源码、NVN 库与 NativeAOT Widen 核心。测试从 `gl_lookup` 取真实 EGL / GL 实现，在宿主栈上直接调用；不替换后端或宽屏函数，不运行游戏的导入 / 切栈层。

在 Apple 芯片 Mac 上运行，需要项目工具链、.NET NativeAOT、`glslangValidator`、`spirv-cross`。首次测试前按下列命令准备依赖；测试本身以 `--no-restore` 发布宽屏核心，不联网。Homebrew .NET 若找不到 OpenSSL / Brotli，给链接器实际安装的库路径：

```sh
export LIBRARY_PATH="$(brew --prefix openssl@3)/lib:$(brew --prefix brotli)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
dotnet restore graphics/widen/S2Arm.Gfx.Widen.csproj -r osx-arm64 \
  --artifacts-path build/tests/nvn/widen-artifacts -p:PublishAot=true -p:NativeLib=Shared
bash graphics/nvn/tests/gl/t_gpu_mip.sh
S2A_WIDEN_DIRECT=1 S2A_SCREEN_W=2346 S2A_WIDEN_FULL=1 bash graphics/nvn/tests/gl/t_gpu_mip.sh
```

默认产物位于 `build/gl-gpu-mip/current/`；`GL_GPU_OUT` 可选择独立目录，`GL_GPU_JOBS` 控制宿主对象的编译并行度。`GL_GPU_ARCHIVE` 可在生产库之前链接保存的 GL 静态库，以相同断言运行旧代码或单变量反证。Metal API / Shader validation 总是开启，编译或像素失败返回非零。

测试用 GL clear / 绘制写入独立 mip 与 cube 面，再显式 LOD 采样，最后一次 GPU 读回核对常量颜色。覆盖六面三级、base / max 变化、组链后再绘制、单级重定义、CPU 上传前后的旧结果保留，另核颜色 / 浮点、私有深度与 BC1 RGB 压缩 mip 尾部及换位。纯组链区间同时检查提交序号和等待计数不变；CPU 上传 / 重定义的既有同步单独排除。

这些是 GPU 接口检查：没有游戏资源、客体代码执行、窗口上屏、移动设备、帧率或能耗证据。宽屏开启时使用不需要放宽的小纹理；已有的非第零级 / cube 附件放宽和宽屏影子 mip 采样限制仍存在。生产宿主在没有 `main.npdm` 的测试进程中会记录未分配游戏地址窗口，此检查不依赖该窗口。
