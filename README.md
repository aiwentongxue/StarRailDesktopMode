# StarRailDesktopMode

StarRailDesktopMode 在 PlayCover 里启用《崩坏：星穹铁道》iOS 客户端自带的 PC 键鼠布局。支持国服和国际服 4.7.0（构建 1），需要 Apple Silicon 和带有用户插件功能的 PlayCover。插件以独立的 arm64 Mac Catalyst dylib 交付，源码按 MIT 授权。

已验证的操作包括 WASD 短按与组合键、右键冲刺、隐藏光标时转动镜头、探索中的滚轮缩放和交互选项切换、Option 呼出和重新锁定，以及打开地图时光标回到视口中心。鼠标灵敏度沿用 PlayCover 设置。手柄左摇杆和十字键可在手机菜单中移动选中项，移动鼠标即可切回键鼠。

探索时按住 `Tab`，移动鼠标选择轮盘方向，松开 `Tab` 打开对应菜单。轮盘方向选择已在 PomPomia 的两服 4.7.0 中实测。

「分辨率」显示当前输出的像素宽高，「渲染精度」提供默认、0.6、0.8 和 1.0。MetalFX 提供关闭、Spatial 和实验性 Temporal。安装方法和实际场景测量见[桌面图形设置](GRAPHICS.md)。

## 安装

1. 下载 [最新 Release](https://github.com/aiwentongxue/StarRailDesktopMode/releases/latest) 中的 `libStarRailDesktopMode.dylib`，然后退出游戏。
2. 打开 PlayCover 的游戏设置，进入插件列表。备份并移除原有的 PC 模式插件或同名预览插件，再导入新版 dylib。
3. 关闭 PlayCover 的「鍵盤映射」，然后启动游戏。在 macOS「控制台」按 `StarRailDesktopMode` 过滤，`desktop_layout=1` 表示 PC 布局已启用。

从 `v0.1.1` 开始，Release 的 dylib 已内置游戏箭头。要替换箭头，将自己的 64×64 PNG 命名为 `cursor.png`，放到以下路径并重启游戏。箭头以 32 点显示，热点按参考图箭尖设在 (8, 3) 点。插件依次使用有效的本机图片、构建时内置的图片和系统箭头。

```text
~/Library/Containers/com.miHoYo.hkrpg/Data/Library/Application Support/StarRailDesktopMode/cursor.png
```

国际服使用同一路径，将容器名替换为 `com.HoYoverse.hkrpgoversea`。

回退时先退出游戏，再从 PlayCover 的插件列表移除本插件。需要恢复旧插件时，重新导入备份的 dylib。

## 已知问题

- 在多个交互物附近打开并退出菜单后，滚动滚轮可能同时切换交互项和缩放镜头。PlayCover 上的新旧插件均复现，Windows 4.7.0 对照只切换交互项。
- 图像设置等列表可按住鼠标左键上下拖动。页面滚轮支持仍待完成。
- 有一次使用系统截图工具后，Option 呼出的游戏箭头切换成了系统箭头。重复截图时未能稳定复现。

复现步骤、对照结果和暂未覆盖的项目见 [真机验证](VERIFICATION.md)。

## 构建

需要 Apple Silicon Mac 和能构建 arm64 Mac Catalyst 动态库的 Xcode。开发使用 Xcode 27.2。

```sh
./Scripts/test.sh
./Scripts/build.sh
```

生成物为 `.build/libStarRailDesktopMode.dylib`。脚本会为产物签名并检查签名。构建所需文件均随源码提供。

如需在本机生成带默认箭头的单文件插件，构建时传入你的 64×64 PNG。图片会直接写入 dylib，导入时只需选择该 dylib。

```sh
SRDM_CURSOR_PNG="/path/to/cursor.png" ./Scripts/build.sh .build/embedded-cursor
```

## 图形诊断

在上述目录创建空文件 `diagnostics`，重启后即可在系统日志中查看保存的渲染精度、分辨率档和 drawable、可采到的渲染附件尺寸和 MetalFX Spatial 输入输出尺寸。只测旧插件时用 `diagnostics-only`，插件此时只做观测。测试完成后移走标记文件并重启游戏。

```sh
log stream --style compact --predicate 'process == "hkrpg" AND eventMessage CONTAINS "StarRailDesktopMode"'
```

判断渲染精度是否生效，要固定同一场景和窗口几何并跟踪同一条主 3D 渲染路径。游戏菜单选中值和 drawable 尺寸是不同的测量量。

## 实现参考

客户端适配校验区服、版本、构建号、UnityFramework UUID 和原生输入入口，再启用游戏的桌面布局。宿主通过 UIKit 和 AppKit 读取视口和指针锁状态。探索时按 Unity 帧合并鼠标相对位移与滚轮增量，轮盘开启时将视口内的鼠标位置同步给游戏。镜头增益沿用 PlayCover 的灵敏度。

视口与光标做法参考 MIT 授权的 GenshinDesktopMode。插件由 PlayCover 的用户插件机制加载。[GenshinDesktopMode](https://github.com/cnSniperMike/GenshinDesktopMode) · [PlayCover 用户插件管理](https://github.com/PlayCover/PlayCover/blob/24bbed7/PlayCover/Utils/PlayTools.swift)
