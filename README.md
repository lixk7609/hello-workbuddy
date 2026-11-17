# Garmin Fenix 7X Connect IQ 应用集

为 Garmin Fenix 7X 开发的两款 Connect IQ 应用（Monkey C），均已上架 Garmin Connect IQ Store。界面为白底黑字加粗风格，顶部有沿屏幕弧度的心率区间刻度柱（灰→蓝→绿→橙→红，由细到粗，按平均心率/进度逐段点亮）。

## 项目一览

| 目录 | 应用 | 类型 | 版本 | 说明 |
|---|---|---|---|---|
| `L-Running/` | L跑步 | 数据字段 (data field) | v1.3.0 | 仿原生跑步数据屏：心率|当前时间 / 距离|计时器 / 配速，顶部心率区间弧柱 |
| `L-WinterRun/` | L冬跑 | 手表应用 (watch-app) | v1.1.1 | 冬季厚手套场景：免摘手套选距离（整数±1公里 / 小数+0.01），按 START 确认后立即搜星并识别跑步姿态，「连续 60 秒跑步姿态 + GPS 已连接」双条件自动开表，跑够预设距离自动停止保存，长按 UP 退出 |

## 目录结构（每个项目相同）

```
manifest.xml        # 应用清单：App ID、类型、机型(fenix7x/pro/pro nowifi)、权限
monkey.jungle       # Monkey C 工程配置
build.sh            # 编译脚本（JDK/SDK/签名密钥路径均可用环境变量覆盖）
source/*.mc         # 主源码
resources/          # 字符串与图标资源
```

## 编译

需要 Connect IQ SDK（9.3.0+）与 JDK 21，签名密钥为 Garmin 格式 developer key：

```bash
./build.sh fenix7x bin/LRunTime.prg     # 编译 prg（USB 侧载）
# 加 -e 打包 .iq（商店上传包）：
#   java -cp $SDK/bin/monkeybrains.jar com.garmin.monkeybrains.Monkeybrains #        -d fenix7x -f monkey.jungle -o out.iq -e -y key.der
```

`JAVA`、`CIQ_SDK`、`KEY` 三个环境变量可覆盖 `build.sh` 内的默认路径。

## 商店素材生成脚本（`tools/`）

商店上架用的图标、横幅、封面、截图全部由脚本生成（Python + Pillow）：

- `make_icons.py` —— 360x360 商店图标 + 40x40 launcher 图标（深蓝底+白 L，跑步=橙秒表 / 冬跑=蓝雪花）
- `make_hero.py` —— 1440x720 商店 Hero 横幅
- `make_store_images.py` —— 500x500 封面 + 280x280 圆屏截图（按真机绘制逻辑 1:1 渲染）

## 关键实现备忘

- **加粗显示**：Garmin 点阵字库无粗体，数值用「横向 3 遍 + 纵向 2 遍」叠印实现
- **心率弧柱**：15 段，-152°→-28°，由细到粗，按平均心率所在区间截断
- **跑步姿态识别**：加速度幅值 stddev/mean > 0.15（跑步约 0.25~0.45，走路 0.08~0.15），需连续 60 秒
- **距离计算**：`Position.LOCATION_CONTINUOUS` 回调速度 × 时间积分
- **CIQ 坑**：`method(:sym)` 间接引用的回调方法不能声明为 `private`（运行时找不到符号，会直接崩溃）；Timer 用 `Toybox.Timer`
