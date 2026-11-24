# 星铁桌面图形设置

适用 Apple Silicon Mac 上的国服及国际服 iOS 4.7.0（构建 1）。图形设置和桌面键鼠共用 `libStarRailDesktopMode.dylib`。

## 安装与使用

1. 退出星铁，在 PlayCover 的星铁设置里打开插件列表。
2. 备份并移除原来的 `libStarRailDesktopMode.dylib`。使用过旧研究版时，同时移除 `libSRDMCaptureResearch.dylib` 等研究插件。
3. 导入交付目录中的新版 `libStarRailDesktopMode.dylib`。启动星铁，打开「设置 → 图像」。
4. 「分辨率」显示当前游戏输出的像素宽高，点击保持收起。「渲染精度」提供默认、0.6、0.8、1.0。选默认后，世界场景恢复由游戏计算的原生尺寸。
5. 将图像设置列表拉到底。MetalFX 的选项为关闭、Spatial（推荐）、Temporal（实验性）。Spatial 使用游戏内置放大，Temporal 接入系统的 MetalFX Temporal。

首次使用时，渲染精度是默认，MetalFX 是关闭。插件在 `SRDMDesktopRenderScale` 和 `SRDMDesktopMetalFX` 中保存选择，重启后沿用。游戏图像预设继续管理原始分辨率和渲染精度，选择默认时由这些原生设置决定场景尺寸。

Temporal 需要系统支持 Apple MetalFX Temporal，并且当前渲染通道提供同帧运动矢量和深度。缺少合格输入时，该帧沿用游戏原生 Spatial。实测使用游戏的 TAA。实验版接入抗锯齿后的颜色，沿用原投影，MetalFX jitter 设为零。

如需单独停用图形功能，退出游戏，在游戏容器的 `Data/Library/Application Support/StarRailDesktopMode/` 里创建空文件 `graphics-disabled`，然后重启游戏。移走同一文件后重新启动即可启用。可用 PlayCover 插件管理替换回已备份的旧版 dylib。

## 实测

实测环境为 M2 Max、macOS 27.3、PlayCover 3.1.0、国服 iOS 4.7.0 build 1。下表是二维市固定 3456×2160 输出时的游戏主场景附件及 MetalFX Temporal 输入尺寸。

| 渲染精度 | 场景颜色、深度和运动矢量 | Temporal 颜色输入 |
| --- | --- | --- |
| 默认 | 2292×1432 | 2292×1432 |
| 0.6 | 2074×1296 | 2074×1296 |
| 0.8 | 2764×1728 | 2765×1728 |
| 1.0 | 3456×2160 | 3456×2160 |

0.8 档的主场景和后处理采用不同的整数舍入。Temporal 转换通道按归一化坐标对齐这一像素的宽差。

- 分辨率行在 3456×2160 和 2880×1800 两种 PlayCover 输出下均与 Metal HUD 匹配。交付版从窗口进入 macOS 全屏后，PlayCover 仍以 3456×2160 输出，分辨率行与 Metal HUD 读数一致。
- 切回默认后，世界场景颜色、深度和运动矢量恢复为该配置的原生 2292×1432。
- 交付版从 Temporal 切到 Spatial，再切回 Temporal 和关闭。返回二维市时，Metal HUD 分别确认了两种放大路径及关闭状态。重新启动验证了 Temporal 选择会保留。

## 实现

- `PlayCoverHost.mm` 通过 bundle ID、版本、构建号和 UnityFramework 的 Mach-O UUID 验证客户端。两服的构建标识见 `Sources/ClientProfile.hpp`。图形入口使用各服的地址表并逐项校验 ARM64 方法序言。以下地址示例来自国服构建。
- `GraphicsSettings.mm` 根据图像页的 Unity 对象层级、行索引和原始选项识别分辨率与渲染精度行。分辨率优先读当前游戏视图的 `CAMetalLayer.drawableSize`，游戏视图暂不可取时读取 Unity `Screen` 尺寸。通过原生 `Text.set_text` 更新文字。Dropdown Show 拦截该行的展开请求。图像页打开期间随输出尺寸更新。
- 渲染精度打开时，临时替换原生下拉列表的四条标签和选中索引。选项点击经原生 `OnSelectItem` 进入，插件单独保存倍率。关闭菜单时游戏的选项数据仍由原来的绑定管理。
- MetalFX 使用 IL2CPP 分配的临时数组生成三个原生 Toggle，设置最终的显示文案。弹层按最后一个选项的实际边界贴到 MetalFX 行上方，避开设置页底部裁切。
- `ConfigureCameraScale` (`0xd634848`) 将当前管线的倍率写入 `MainCamera` 的相机数据 (`+0x5c`)，游戏据此分配主场景颜色、深度和运动矢量。`ApplyCameraSettings` (`0xd61cd60`) 将对应倍率及场景尺寸送入原生后处理重建路径。两处调用均通过 `0xd61b6ac` 取当前管线，只在原函数执行期间覆盖倍率，退出即恢复。默认档直接执行原函数，保留游戏原生分辨率。只覆盖 Apply 会留下原生尺寸的几何附件。
- 版本识别、输出尺寸和默认恢复策略参考 Paimonia。星铁通过两处原生相机入口计算渲染尺寸，游戏负责重建纹理和视口。

### MetalFX 路径

- 游戏构建后处理命令的入口位于 `0xd64ed34`。插件在这次调用里按三档选择控制原生 Spatial 开关，退出该调用后恢复配置字段。关闭调用原生关闭路径。Spatial 调用原生放大。Temporal 先由游戏分配原生放大输入和输出，再替换同一个主场景编码位置。
- `TemporalMetalFX.mm` 同时核对命令缓冲区、尺寸和纹理格式。世界场景的运动矢量存于 `RG8Unorm` 附件，关联反向深度为 `Depth32Float_Stencil8`。两者需同尺寸，与后处理颜色在各轴最多相差一个像素。以静止值 127 为零，逐通道将 `(u8 - 127) / 127` 还原为带符号的平方，再取负得到当前像素到上一帧的归一化位移。乘输入宽高换算为像素。运动方向和量级由相邻游戏帧的实际像素位移校准。
- 使用同一 Metal 命令缓冲区，将感知颜色转为线性 `RGBA16Float`、深度复制为 `R32Float`、矢量转换为 `RG16Float`。Apple `MTLFXTemporalScaler` 输出线性颜色，再转换回 `RGBA8Unorm`，写入原生放大路径的输出。游戏继续合成全分辨率 HUD。新尺寸、切换模式、深度目标重建或编码间断后重置历史。缓冲提交时清理未消费的附件记录。
- 可在 Metal HUD 中核对 `Scaling` 是 Spatial 还是 Temporal，或在「控制台」按 `[StarRailDesktopMode] Temporal` 查看 GPU 完成与回退日志。[Apple MetalFX Temporal](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscaler)

## 构建与维护

```sh
./Scripts/test.sh
SRDM_CURSOR_PNG="$PWD/崩坏：星穹铁道.png" ./Scripts/build.sh
```

在源码仓库根目录运行，生成 `.build/libStarRailDesktopMode.dylib`。不内置光标时可直接运行 `./Scripts/build.sh`。换客户端版本时重新定位菜单、主相机和后处理入口，核对原生对象路径及字段后更新构建标识和 Hook 序言。使用同一场景核对四档场景颜色、深度及运动矢量的像素尺寸，再验证三种放大模式、窗口与全屏输出以及重启后的选项状态。
