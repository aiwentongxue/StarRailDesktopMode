# 国服 4.7.0 真机验证

环境为 M2 Max、macOS 27.3、PlayCover 3.1.0，使用国服 iOS 4.7.0 build 1。国服 UnityFramework UUID 为 `264C6E79-85C7-308E-B9F9-CC36EF18ACBB`。

## 桌面模式和光标

| 验收项 | 结果 |
| --- | --- |
| arm64 Mac Catalyst 构建与签名 | 通过 |
| 配置匹配、视口坐标、回中状态、合并位移单测 | 通过 |
| 新 dylib 单独加载并进入游戏世界 | 通过。仅加载本插件，关闭 PlayCover 键盘映射。日志显示 `desktop_layout=1`，世界界面出现 `V`、`Enter`、队伍 `1`–`4`、`E` 和鼠标图标 |
| 原生桌面输入 | 用户确认短按 W、长按 W 加 A 或 Shift、松开部分或全部按键均正常。长按 W 加右键可以冲刺。`M` 能打开地图，`Esc` 能返回并打开手机菜单，鼠标能点击图像设定。窗口自动化测试中地图未响应拖动，战斗、文本输入、手柄和高回报率待验收 |
| 加载本机光标 PNG | 运行日志确认 `custom_arrow=1`。用户确认在视口内移动时保持游戏箭头样式 |
| 探索到地图的光标回中 | 用户在窗口模式按 `M` 打开地图后确认回到画面中心。两点误差阈值、连续切换、全屏、副屏及游戏指针同步待验收 |

## WASD 对照

PlayCover 键盘映射关闭，固定约 30 FPS。完整独立插件和仅启用 PC 布局的独立实验均复现按下、松开滞后及短按位移过大。用户用同一机器对照旧插件，确认其短按和松开响应正常。

在两组采样中，AppKit 均收到移动键按下和松开。独立插件的短按样本中，事件到达进程的时间通常在数毫秒至十几毫秒内。游戏的输入管理器在两组均显示模式 `2`。

持续按 `W` 时短按 Shift，用户确认角色加速后停跑。Shift 松开后约 1.1 秒，Quartz 与 GameController 的 `W` 状态仍持续为按下，AppKit 在实际松手时才记录到 `W` 松开。持续按 `W` 与 `A` 也会停跑或丢掉一个方向。该组记录中两个键各自的按下和松开事件完整。

在国服 UnityFramework 的原生键盘实现中，`UnityView.processKeyboard` 对 UIKeyCommand 生成的按键以 0.5 秒超时补发松开。新桥接在游戏窗口拥有输入时，直接把 AppKit 的按下和松开传给同一 Unity 原生入口，并独立跟踪各键。用户使用仅加载独立插件的测试版复测，确认短按 W，以及长按 W 时交替按放 A 和 Shift，移动开始、持续和停止均正常。[Unity Input.GetKey 文档](https://docs.unity3d.com/jp/current/ScriptReference/Input.GetKey.html)

## 光标切换

游戏探索时请求隐藏和锁定指针，打开地图时请求显示并解锁。宿主优先在前台游戏窗口用 Quartz 同步隐藏并捕获指针，失败时请求 Catalyst 指针锁定。镜头只在捕获成功时接收位移。菜单和失焦会释放捕获并清除累计位移。[Apple Quartz 相对指针](https://developer.apple.com/documentation/coregraphics/cgassociatemouseandmousecursorposition(_:)) · [Apple Catalyst 指针锁定](https://developer.apple.com/documentation/uikit/uiviewcontroller/preferspointerlocked?language=objc)

重新锁定把物理指针固定在游戏视口中心。用户在窗口模式复测，将指针移出游戏窗口后松开 Option，随后呼出能回中，点击继续由游戏接收。按住 Option 在视口内移动时，用户确认游戏箭头样式稳定。显示时已在中心两点以内便直接释放指针，需要定位时在定位后恢复关联。用户确认呼出后的首段移动流畅。[GenshinDesktopMode 光标实现](https://github.com/cnSniperMike/GenshinDesktopMode/blob/b0fe5fc6f51b80d4c7a1141b3284732c76d6bd57/genshin/pointer_bridge.h) · [SDL 的 Cocoa 指针定位](https://github.com/libsdl-org/SDL/blob/main/src/video/cocoa/SDL_cocoamouse.m#L548-L571)

独立输入测试中，国服客户端从 `mouse x`、`mouse y` 读取镜头位移。日志记录了 AppKit 位移累加、Unity 帧计数以及菜单和失焦时释放捕获。用户确认光标隐藏时可以直接转动镜头，横向和纵向方向正常。基础镜头增益调为初版的 2.5 倍，继续使用 PlayCover 灵敏度。用户复测确认速度合适，松开 Option 后指针立即隐藏并恢复转向。

重新锁定时从首个相对移动事件扣除视口回中位移。捕获期间鼠标按钮的按下和松开送入原生 Unity 输入，释放捕获时松开仍被桥接持有的按钮。用户复测把指针移至视口边缘，再松开 Option 并轻移鼠标，镜头平稳。长按 W 时点右键可进入冲刺。

## 图形设置对照

触控布局的图像菜单提供固定「分辨率」档，对应 `GraphicsSettings_Model.ResolutionQuality`。新旧插件启用 PC 布局后均额外显示「渲染精度」，对应同一对象的 `RenderScale`。

独立插件的即时测试中，菜单从 `1.0` 依次切到 `0.8` 和 `0.6`，偏好文件同步保存，固定分辨率仍为档 5。每次返回同一世界视角，三档的 MetalFX Spatial 输入均为 `2292×1432`，输出均为 `3456×2160`。渲染精度暂未通过验收。

以下是旧插件启用时的重启对照。每次只使用 PlayCover 下的已安装客户端，外加只读探针记录标题场景的 MetalFX Spatial 输入输出尺寸。

| 保存的渲染精度 | 固定分辨率档 | Spatial 输入 | 输出 |
| --- | --- | --- | --- |
| 1.0 | 5 | 2292×1432 | 3456×2160 |
| 0.6 | 5 | 2292×1432 | 3456×2160 |
| 1.0 | 3 | 1966×1229 | 3456×2160 |

固定分辨率档能改变这一条缩放路径的输入尺寸。在该路径上，单独把保存的渲染精度从 1.0 改成 0.6 未改变实际输入。已在旧插件的 0.6 世界画面看到相同 Spatial 输入。世界主相机的颜色、深度及有效 viewport 尚无完整采样。

## 参考 Paimonia 的后续适配

Paimonia 读取 Unity 输出作为尺寸基准，按档位计算场景尺寸，把宽高对齐到偶数。它给世界主相机应用新的渲染尺寸，然后调用原生相机画质刷新来重建目标。验收测量主相机的颜色和深度，独立核对 drawable。恢复档会在相机可用时还原原生尺寸。

迁移到星穹铁道时，先定位本客户端的世界主相机尺寸和原生重建入口，使用本客户端的 UnityFramework UUID 验证适配，再绑定 PC 菜单的 `RenderScale`。用 `1.0 → 0.8 → 0.6 → 1.0` 实测同一世界场景的颜色和深度，核对窗口 drawable、UI 和点击位置。保留「分辨率」与「渲染精度」两项各自的作用。
