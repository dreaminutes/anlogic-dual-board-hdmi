# 基于安路FPGA的双板协同HDMI多媒体展示系统

最终 **V10** 工程。两块安路 **EG4S20BG256** FPGA 协同运行：副板读取 TF 卡并提供媒体数据，主板负责缓存、图层合成、音频分析与 HDMI 音视频输出。已完成整机上板验证。

支持 BMP 图片、GIF 动图、DBV 视频和 WAV 音频，包含图像缩放与转场、字幕与菜单、音频频谱、独立音乐可视化及按键交互。上电默认手动切换，字幕和媒体频谱叠加默认关闭。

## 目录

| 目录 | 内容 |
| --- | --- |
| `fpga/main_v10/` | V10 主板 RTL、IP、约束、TD 工程与构建脚本 |
| `fpga/secondary_library/` | 配套副板完整工程 |
| `bit/` | 已验证的主副板配套下载文件 |
| `media_tools/` | 视频、音频、静态图片及 GIF 转换程序源码 |
| `docs/` | 双板连接、启动顺序和按键操作说明 |

## FPGA 工程与构建

工具：**TangDynasty TD 6.2.1 Engineer（6.2.168.116）**，目标器件 **EG4S20BG256**。主板和副板是两个独立工程，分别构建、分别下载。

将仓库放到短英文路径，例如 `D:\FPGA_Media`。在 PowerShell 中设置 `TD_EXE` 为本机 `td_commands_prompt.exe` 的完整路径，或把对应 `bin` 目录加入 `PATH`。

```powershell
cd fpga/main_v10
.\build.cmd -Stage Validate

cd ../secondary_library
.\build.cmd -Stage Validate
```

`Validate` 只分析源码、展开工程和加载约束；不启动布局布线。完整构建使用 `-Stage All`，也可分别执行 `Synthesis`、`Physical`、`Bit`。构建结果保存在各工程的 `build/` 下。

GUI 工程入口：

- [主板 main_v10.al](fpga/main_v10/main_v10.al)
- [副板 secondary_library.al](fpga/secondary_library/secondary_library.al)

复现最终实现时使用提供的构建脚本。详细配置、阶段和环境说明见 [FPGA 工程使用说明](fpga/工程使用说明.txt)。

## 直接上板

主副板分别使用以下文件，无需为转换新素材重新生成 BIT：

- 主板：[double_board_2_main_sw4_V10_TEST.bit](bit/double_board_2_main_sw4_V10_TEST.bit)
- 副板：[COMPAT_double_board_1_secondary_library_TEST.bit](bit/COMPAT_double_board_1_secondary_library_TEST.bit)

TF 卡连接副板，HDMI 连接主板。连接排线前断电，按 [双板连接与操作](docs/双板连接与操作.txt) 完成接线、下载及启动；更完整的针号表和素材要求见 [双板连接与运行说明](docs/双板连接与运行.txt)。

## 素材转换

仓库提供转换器源码，**不附带 Python、Pillow 和 FFmpeg 的便携执行环境**。源码运行需要 **Python 3.12 或更高版本、Pillow 和 FFmpeg**；本项目已使用 Python 3.12 与 Pillow 12.3.0 验证。Windows 可安装依赖后双击 `media_tools/00_启动转换工具.cmd`，也可把文件拖到 `01` 至 `04` 对应转换入口。

```powershell
python -m pip install -r media_tools/requirements.txt
python media_tools/media.py --help
```

FFmpeg 可加入 `PATH`、通过环境变量 `FFMPEG_EXE` 指定，或在命令中传入 `--ffmpeg`。安装来源：[Python](https://www.python.org/)、[Pillow](https://pillow.readthedocs.io/)、[FFmpeg](https://ffmpeg.org/download.html)。

```powershell
python media_tools/media.py video "input.mp4"
python media_tools/media.py audio "input.mp3"
python media_tools/media.py image "input.png"
python media_tools/media.py gif "input.gif"
```

输出位于 `media_tools/output/` 新建的批次目录，输入文件不会被覆盖。输出格式：

- 视频：640×480、默认 20 FPS 的 DBV2；带原声每段建议不超过 42 秒，较长视频可分段或使用 `--no-audio` 转为 DBV1。
- 音频：48 kHz、16 位、单声道 PCM WAV，固定 44 字节头。
- 静态图片：24 位未压缩 BMP，默认保留输入尺寸。
- GIF：640×480，保留合成画面、有效帧延时与循环参数。

生成的 BMP、GIF、DBV、WAV 文件手动复制到 FAT32 TF 卡根目录；具体限制、命名与批量操作见 [素材转换使用说明](media_tools/使用说明.txt)。

完整参赛 RAR 是便携包，含 Windows x64 执行环境；若从仓库 **Releases** 下载便携包，完整解压后可直接使用其中的转换入口。仓库源码与便携包中的 V10 工程、BIT 和转换程序保持一致。

## 第三方组件

原厂 IP、源码版权注释和第三方许可保持原样。TD 软件与器件数据库需自行安装，不随仓库分发。Python、Pillow、FFmpeg 的许可及来源见 [第三方组件说明](media_tools/runtime/第三方组件说明.txt) 和 [许可证目录](media_tools/runtime/licenses/)。本仓库未为包含的所有组件另行指定统一开源许可证。
