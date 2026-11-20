import { program } from './screens.js';

/**
 宣传片里用到的真实录屏片段（scripts/extract.js 拆好的帧，assets/rec/ake/…）。
 from 是阿珂那台手机录屏自己的秒数（= 剪辑表里的墙上时间 − 0.935）。
 没有录屏帧时（REC = null）各镜头退回用 design/screens/app 的定稿截图。
*/
const hasRec = await fetch('assets/rec/manifest.json').then((r) => r.ok).catch(() => false);

export const REC = hasRec ? {
  // G：漏报提醒。阿珂手机弹出「请尝试联系小林」（墙上 319.4 秒起，323.9 秒她才点确认）
  missAke: program([{ at: 0, seq: 'ake', from: 318.47, rate: 1 }], { time: '00:08' }),
  // 妈妈那台没有录屏：用阿珂列表里「联系不上，请尝试联系她」那一刻（墙上 315 秒），两人看到的是同一张卡片
  missMom: program([{ at: 0, seq: 'ake', from: 314.07, rate: 0 }], { time: '00:08' }),
  // H：求救。阿珂手机上「小林发起了求救」（墙上 353 秒起，357.2 秒她才点确认）
  sosAke: program([{ at: 0, seq: 'ake', from: 352.07, rate: 1 }], { time: '00:21' }),
} : null;
