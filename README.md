# StarRailDesktopMode

《崩坏：星穹铁道》在 PlayCover 上的桌面输入兼容性预览。当前客户端配置为国服 iOS 4.7.0 build 1，运行时核对 Bundle ID 和 UnityFramework UUID。适配以独立 Mac Catalyst dylib 交付。

当前源码在国服 iOS 4.7.0 build 1 启用游戏自带的 PC 键鼠布局。真机已验证短按与组合键移动、右键冲刺、隐藏光标时转动镜头、Option 呼出和重新锁定，以及打开地图时光标回到视口中心。游戏菜单会保存渲染精度，`0.6 / 0.8 / 1.0` 的主 3D 渲染尺寸尚未通过验收。具体结果见 [真机验证](VERIFICATION.md)。

## 构建

需要 Apple Silicon Mac 和能构建 arm64 Mac Catalyst 动态库的 Xcode。开发使用 Xcode 27.2。

```sh
./Scripts/test.sh
./Scripts/build.sh
```

生成物为 `.build/libStarRailDesktopMode.dylib`。构建会签名并校验；源码和预览包可直接构建，无需游戏文件或专有素材。

## 本地测试与恢复

1. 退出游戏。在 PlayCover 的游戏设置中打开插件列表，将原有的 PC 模式 dylib 先保留一份，再从列表移除。
2. 如果列表已有同名预览插件，先移除该条目，再导入这次构建的 `libStarRailDesktopMode.dylib`。确认 PlayCover 的「鍵盤映射」关闭，避免和游戏自身的键鼠输入叠加。启动后可在系统「控制台」按 `StarRailDesktopMode` 过滤，`desktop_layout=1` 表示 PC 布局已启用。
3. 使用自定义箭头时，将本机的 64×64 PNG 命名为 `cursor.png`，放到以下目录，然后重启游戏。箭头以 32 点显示，热点按参考图箭尖设在 (8, 3) 点。其余应用与窗口控件使用自己的指针形状。

```text
~/Library/Containers/com.miHoYo.hkrpg/Data/Library/Application Support/StarRailDesktopMode/cursor.png
```

恢复旧插件时先退出游戏，在同一列表移除预览 dylib，再重新导入原插件。

## 图形诊断

在上述目录创建空文件 `diagnostics`，重启后即可在系统日志中查看保存的渲染精度、分辨率档和 drawable、可采到的渲染附件尺寸和 MetalFX Spatial 输入输出尺寸。只测旧插件时用 `diagnostics-only`，预览 dylib 此时只做观测。测试完成后移走标记文件并重启游戏。

```sh
log stream --style compact --predicate 'process == "hkrpg" AND eventMessage CONTAINS "StarRailDesktopMode"'
```

判断渲染精度是否生效，要固定同一场景和窗口几何并跟踪同一条主 3D 渲染路径。游戏菜单选中值和 drawable 尺寸是不同的测量量。

## 实现参考

客户端适配核对国服构建标识和原生输入入口，再启用游戏的桌面布局。宿主通过 UIKit 和 AppKit 读取视口和指针锁状态。桥接用实际的按下和松开事件更新 Unity 的键盘与鼠标按钮。探索时按 Unity 帧合并相对位移，并从首个鼠标事件扣除重新锁定时的定位位移。镜头增益沿用 PlayCover 的灵敏度。图形探针记录已保存的设置和渲染尺寸。

视口与光标做法参考 MIT 授权的 GenshinDesktopMode。插件由 PlayCover 的用户插件机制加载。[GenshinDesktopMode](https://github.com/cnSniperMike/GenshinDesktopMode) · [PlayCover 用户插件管理](https://github.com/PlayCover/PlayCover/blob/24bbed7/PlayCover/Utils/PlayTools.swift)
