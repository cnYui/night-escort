# 安全回家：使用视频和宣传片

这里是两支视频的渲染工程，都用浏览器逐帧渲染再用 ffmpeg 合成，素材全部来自本仓库和 Air 上的录屏，不用外部图片或音乐。

- 使用视频（约 2 分 20 秒）：`usage.html` + `src/usage.js`。左边小林、右边阿珂两台 iPhone 的真实录屏并排，左侧小窗是小林的手表，按 `assets/usage-edl.json` 剪辑，配章节条和字幕。
- 宣传片（66 秒）：`index.html` + `src/main.js`、`src/shots.js`。three.js 做的雨夜街道、地图、手机和手表特写，分镜在 `src/shots.js`。主角模型放 `assets/models/woman.glb`（Tripo 生成、带原地走路动画）；没有这个文件时用一个简单的占位小人。
- 配乐和音效：`audio.py`（numpy 合成，提示音用 App 自带的 `ios/NightEscort/Resources/Sounds`）。

## 准备

需要 Node 18+、ffmpeg、Python 3（numpy，有 scipy 更好）。浏览器默认用系统自带的 Edge（Windows）或 Playwright 的 Chromium。

```
cd video
npm install
node scripts/extract.js <录屏目录>     # ios/scripts/record-tour.sh 的输出：xiaolin.mp4、ake.mp4、watch-scenes/
node make.js info usage                # 看 WebGL 用的是显卡还是软件渲染
```

## 渲染

```
node make.js preview usage 6,25,90     # 先看几帧，存到 out/preview-usage/
node make.js render usage              # 成片 out/usage.mp4
node make.js preview promo 3,15,42
node make.js render promo              # 成片 out/promo.mp4
```

中断了直接重跑同一条命令，已经渲染好的帧会跳过。`--workers N` 调并行页面数。环境变量 `GL=swiftshader` 可以在没有显卡的机器上用软件渲染（慢很多）；`PAGE_QUERY=yaw=3.14` 之类可以给页面传参数（比如主角模型朝向不对时调 `yaw`，单位弧度）。

## 剪辑表

`assets/usage-edl.json` 里的时间是“墙上时间”：从小林那台手机开始录屏算起的秒数。两台手机的对齐是按 `record-tour.sh` 的 `times.txt` 和两段 XCUITest 日志里的 `Start Test at` 算的（两边都在第 129.1 秒左右开始），再用后端日志里出发、报平安、拨时钟、确认安全、结束这几个请求的时间核对过，误差在一秒内。

模拟器里手表和手机没有同步上，所以使用视频里的手表画面是演示模式下各页面的短片（`watch-scenes`），按剧情切换。
